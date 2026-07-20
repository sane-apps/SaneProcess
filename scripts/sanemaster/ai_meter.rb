# frozen_string_literal: true

require 'date'
require 'json'
require 'net/http'
require 'time'
require 'uri'

module SaneMasterModules
  module AIMeter
    DATASET = 'sane_ai_meter'
    SCHEMA_VERSION = 'v1'
    PRODUCTS = %w[sanelot sanecite].freeze
    TASKS = %w[
      photo_classification listing_description lead_reply honesty_adjudication
      evidence_embedding query_embedding answer_generation support_verification
      question_extraction library_embedding embedding_canary unknown
    ].freeze
    CONTEXTS = %w[
      production ingest questionnaire_run questionnaire_parse library
      library_reuse api_batch admin_probe canary review_edit
    ].freeze
    ROUTES = %w[direct gateway].freeze
    OUTCOMES = %w[success error timeout rate_limited fallback_success].freeze
    USAGE_STATES = %w[available partial missing].freeze
    SAFE_MODEL = /\A[A-Za-z0-9@._\/:+\-]{1,128}\z/
    RATE_SOURCE = 'https://developers.cloudflare.com/workers-ai/platform/pricing/'
    RATE_VERIFIED_ON = Date.new(2026, 7, 8)
    RATE_MAX_AGE_DAYS = 30
    MODEL_RATES = {
      '@cf/google/gemma-4-26b-a4b-it' => { input: 0.100, output: 0.300 },
      '@cf/meta/llama-3.3-70b-instruct-fp8-fast' => { input: 0.293, output: 2.253 },
      '@cf/meta/llama-3.1-8b-instruct-fp8-fast' => { input: 0.045, output: 0.384 },
      '@cf/openai/gpt-oss-120b' => { input: 0.350, output: 0.750 },
      '@cf/baai/bge-large-en-v1.5' => { input: 0.204, output: 0.0 }
    }.freeze

    def ai_meter(args = [])
      options = parse_ai_meter_options(args)
      query = query_ai_meter(
        days: options[:days],
        token: ENV['CLOUDFLARE_API_TOKEN'],
        account_id: ENV['CLOUDFLARE_ACCOUNT_ID']
      )
      report =
        if query[:state] == 'ready'
          build_ai_meter_report(query[:rows], days: options[:days])
        else
          ai_meter_state_report(query[:state], query[:reason], days: options[:days])
        end

      output =
        if options[:json]
          JSON.pretty_generate(report)
        elsif options[:markdown]
          render_ai_meter_markdown(report)
        else
          render_ai_meter_text(report)
        end
      puts output
      report
    end

    def parse_ai_meter_options(args)
      options = { days: 7, json: false, markdown: false }
      index = 0
      while index < args.length
        case args[index]
        when '--days'
          index += 1
          raise ArgumentError, '--days requires an integer' unless args[index]&.match?(/\A\d+\z/)

          options[:days] = args[index].to_i
          raise ArgumentError, '--days must be between 1 and 90' unless (1..90).cover?(options[:days])
        when '--json'
          options[:json] = true
        when '--markdown'
          options[:markdown] = true
        else
          raise ArgumentError, "unknown ai_meter option: #{args[index]}"
        end
        index += 1
      end
      raise ArgumentError, '--json and --markdown are mutually exclusive' if options[:json] && options[:markdown]

      options
    end

    def query_ai_meter(days:, token:, account_id:)
      return { state: 'unavailable', reason: 'cloudflare_credentials_missing', rows: [] } if token.to_s.empty? || account_id.to_s.empty?

      sql = ai_meter_sql(days)
      uri = URI("https://api.cloudflare.com/client/v4/accounts/#{account_id}/analytics_engine/sql")
      status, body = ai_meter_http_post(uri, token, sql)
      return { state: 'query_error', reason: "cloudflare_http_#{status}", rows: [] } unless status.between?(200, 299)

      payload = JSON.parse(body)
      if payload.is_a?(Hash) && payload['success'] == false
        return { state: 'query_error', reason: 'cloudflare_query_rejected', rows: [] }
      end

      rows =
        if payload.is_a?(Array)
          payload
        elsif payload.is_a?(Hash)
          payload['data'] || payload['result'] || payload['rows'] || []
        else
          []
        end
      return { state: 'query_error', reason: 'cloudflare_response_invalid', rows: [] } unless rows.is_a?(Array)

      { state: 'ready', reason: nil, rows: rows }
    rescue JSON::ParserError
      { state: 'query_error', reason: 'cloudflare_response_invalid_json', rows: [] }
    rescue StandardError => e
      { state: 'query_error', reason: "cloudflare_request_#{e.class.name.split('::').last.downcase}", rows: [] }
    end

    def ai_meter_http_post(uri, token, sql)
      request = Net::HTTP::Post.new(uri)
      request['Authorization'] = "Bearer #{token}"
      request['Content-Type'] = 'text/plain'
      request.body = sql
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
        http.request(request)
      end
      [response.code.to_i, response.body.to_s]
    end

    def ai_meter_sql(days)
      <<~SQL
        SELECT
          index1 AS indexed_product,
          blob1 AS event_type,
          blob2 AS schema_version,
          blob3 AS product,
          blob4 AS task,
          blob5 AS context,
          blob6 AS model,
          blob7 AS route,
          blob8 AS outcome,
          blob9 AS usage_state,
          double8 AS quality_code,
          SUM(_sample_interval) AS calls,
          sumIf(_sample_interval, double1 > 1) AS retries,
          sumIf(_sample_interval, blob8 = 'fallback_success') AS fallbacks,
          SUM(double2 * _sample_interval) AS latency_weighted_ms,
          SUM(double3 * _sample_interval) AS input_tokens,
          SUM(double4 * _sample_interval) AS output_tokens,
          SUM(double5 * _sample_interval) AS total_tokens,
          SUM(double6 * _sample_interval) AS usage_available_calls,
          SUM(double7 * _sample_interval) AS successes,
          MAX(timestamp) AS data_through
        FROM #{DATASET}
        WHERE timestamp >= NOW() - INTERVAL '#{Integer(days)}' DAY
          AND index1 IN ('sanelot', 'sanecite')
          AND blob1 = 'inference_attempt'
          AND blob2 = '#{SCHEMA_VERSION}'
        GROUP BY index1, blob1, blob2, blob3, blob4, blob5, blob6, blob7, blob8, blob9, double8
        ORDER BY product, task, model, context, outcome
      SQL
    end

    def build_ai_meter_report(raw_rows, days:, now: Date.today)
      return ai_meter_state_report('delayed', 'no_events_in_window', days: days) if raw_rows.empty?

      invalid_rows = 0
      rows = raw_rows.filter_map do |row|
        normalized = normalize_ai_meter_row(row)
        invalid_rows += 1 unless normalized
        normalized
      end
      return ai_meter_state_report('query_error', 'schema_mismatch', days: days) if rows.empty?

      products = PRODUCTS.to_h { |product| [product, summarize_ai_meter_rows(rows.select { |row| row[:product] == product }, now: now)] }
      totals = summarize_ai_meter_rows(rows, now: now)
      warnings = []
      warnings << "#{invalid_rows} schema-invalid row(s) ignored" if invalid_rows.positive?
      warnings.concat(totals[:warnings])

      {
        state: 'ready',
        dataset: DATASET,
        schema_version: SCHEMA_VERSION,
        window_days: days,
        data_through: rows.filter_map { |row| row[:data_through] }.max,
        pricing: {
          state: totals[:cost_state],
          verified_on: RATE_VERIFIED_ON.iso8601,
          max_age_days: RATE_MAX_AGE_DAYS,
          source: RATE_SOURCE,
          basis: 'Estimated recurring gross post-credit cost at published token rates; not invoice or credit truth.'
        },
        quality: inference_quality_status,
        totals: totals.reject { |key, _| key == :warnings },
        products: products.transform_values { |summary| summary.reject { |key, _| key == :warnings } },
        warnings: warnings.uniq
      }
    end

    def normalize_ai_meter_row(row)
      product = row_value(row, 'product').to_s
      return nil unless PRODUCTS.include?(product)
      return nil unless row_value(row, 'indexed_product').to_s == product
      return nil unless row_value(row, 'schema_version').to_s == SCHEMA_VERSION
      return nil unless row_value(row, 'event_type').to_s == 'inference_attempt'

      task = row_value(row, 'task').to_s
      context = row_value(row, 'context').to_s
      model = row_value(row, 'model').to_s
      route = row_value(row, 'route').to_s
      outcome = row_value(row, 'outcome').to_s
      usage_state = row_value(row, 'usage_state').to_s
      return nil unless TASKS.include?(task)
      return nil unless CONTEXTS.include?(context)
      return nil unless SAFE_MODEL.match?(model)
      return nil unless ROUTES.include?(route)
      return nil unless OUTCOMES.include?(outcome)
      return nil unless USAGE_STATES.include?(usage_state)

      {
        event_type: 'inference_attempt',
        product: product,
        task: task,
        context: context,
        model: model,
        route: route,
        outcome: outcome,
        usage_state: usage_state,
        quality_code: quality_code(row_value(row, 'quality_code')),
        calls: finite_number(row_value(row, 'calls')),
        retries: finite_number(row_value(row, 'retries')),
        fallbacks: finite_number(row_value(row, 'fallbacks')),
        latency_weighted_ms: finite_number(row_value(row, 'latency_weighted_ms')),
        input_tokens: finite_number(row_value(row, 'input_tokens')),
        output_tokens: finite_number(row_value(row, 'output_tokens')),
        total_tokens: finite_number(row_value(row, 'total_tokens')),
        usage_available_calls: finite_number(row_value(row, 'usage_available_calls')),
        successes: finite_number(row_value(row, 'successes')),
        data_through: parse_ai_meter_time(row_value(row, 'data_through'))
      }
    rescue ArgumentError
      nil
    end

    def summarize_ai_meter_rows(rows, now:)
      calls = rows.sum { |row| row[:calls] }
      successes = rows.sum { |row| row[:successes] }
      latency_sum = rows.sum { |row| row[:latency_weighted_ms] }
      usage_calls = rows.sum { |row| row[:usage_available_calls] }
      input_tokens = rows.sum { |row| row[:input_tokens] }
      output_tokens = rows.sum { |row| row[:output_tokens] }
      total_tokens = rows.sum { |row| row[:total_tokens] }
      retries = rows.sum { |row| row[:retries] }
      fallbacks = rows.sum { |row| row[:fallbacks] }
      unpriced_models = rows.select { |row| row[:calls].positive? && !MODEL_RATES.key?(row[:model]) }.map { |row| row[:model] }.reject(&:empty?).uniq.sort
      rate_stale = (now - RATE_VERIFIED_ON).to_i > RATE_MAX_AGE_DAYS
      estimate = nil
      cost_state =
        if rate_stale
          'stale_rates'
        elsif unpriced_models.any?
          'unpriced_usage'
        else
          estimate = rows.sum do |row|
            rate = MODEL_RATES.fetch(row[:model], { input: 0.0, output: 0.0 })
            ((row[:input_tokens] * rate[:input]) + (row[:output_tokens] * rate[:output])) / 1_000_000.0
          end
          calls.positive? && usage_calls < calls ? 'partial_usage' : 'estimated'
        end

      warnings = []
      warnings << "unpriced model(s): #{unpriced_models.join(', ')}" if unpriced_models.any?
      warnings << "pricing verification is older than #{RATE_MAX_AGE_DAYS} days" if rate_stale
      warnings << 'token usage is missing for some measured calls' if calls.positive? && usage_calls < calls

      {
        calls: round_count(calls),
        successes: round_count(successes),
        errors: round_count([calls - successes, 0].max),
        retries: round_count(retries),
        fallbacks: round_count(fallbacks),
        weighted_average_latency_ms: calls.positive? ? (latency_sum / calls).round(1) : nil,
        input_tokens: round_count(input_tokens),
        output_tokens: round_count(output_tokens),
        total_tokens: round_count(total_tokens),
        measured_token_coverage_pct: calls.positive? ? ((usage_calls / calls) * 100).round(1) : nil,
        gross_post_credit_estimated_usd: estimate&.round(6),
        cost_state: cost_state,
        unpriced_models: unpriced_models,
        warnings: warnings
      }
    end

    def ai_meter_state_report(state, reason, days:)
      {
        state: state,
        dataset: DATASET,
        schema_version: SCHEMA_VERSION,
        window_days: days,
        data_through: nil,
        pricing: {
          state: 'not_computed',
          verified_on: RATE_VERIFIED_ON.iso8601,
          max_age_days: RATE_MAX_AGE_DAYS,
          source: RATE_SOURCE,
          basis: 'Estimate unavailable until measured data is available.'
        },
        quality: inference_quality_status,
        totals: nil,
        products: {},
        warnings: [reason].compact
      }
    end

    def render_ai_meter_text(report)
      lines = ["AI meter (#{report[:window_days]}d)", "State: #{report[:state]}"]
      if report[:state] == 'ready'
        totals = report[:totals]
        lines << "Data through: #{report[:data_through] || 'unknown'}"
        lines << "Calls #{totals[:calls]} | errors #{totals[:errors]} | retries #{totals[:retries]} | fallbacks #{totals[:fallbacks]}"
        lines << "Weighted average latency: #{format_optional(totals[:weighted_average_latency_ms], ' ms')}"
        lines << "Measured token coverage: #{format_optional(totals[:measured_token_coverage_pct], '%')}"
        lines << "Estimated gross post-credit cost: #{format_cost(totals)}"
        lines << 'Inference quality: unknown; separate canaries and benchmarks were not run'
      else
        lines << "Reason: #{report[:warnings].join(', ')}"
      end
      lines.join("\n")
    end

    def render_ai_meter_markdown(report)
      lines = ["## AI Usage & Cost (#{report[:window_days]}-day)", '']
      unless report[:state] == 'ready'
        lines << "**Status:** #{report[:state]} (#{report[:warnings].join(', ')})"
        lines << ''
        lines << '---'
        return lines.join("\n")
      end

      totals = report[:totals]
      lines << "**Status:** ready; data through #{report[:data_through] || 'unknown'}"
      lines << ''
      lines << '| Scope | Calls | Errors | Retries | Fallbacks | Avg latency | Token coverage | Estimated gross post-credit cost |'
      lines << '|-------|------:|-------:|--------:|----------:|------------:|---------------:|---------------------------------:|'
      report[:products].each do |product, summary|
        lines << "| #{product} | #{summary[:calls]} | #{summary[:errors]} | #{summary[:retries]} | #{summary[:fallbacks]} | #{format_optional(summary[:weighted_average_latency_ms], ' ms')} | #{format_optional(summary[:measured_token_coverage_pct], '%')} | #{format_cost(summary)} |"
      end
      lines << "| Portfolio | #{totals[:calls]} | #{totals[:errors]} | #{totals[:retries]} | #{totals[:fallbacks]} | #{format_optional(totals[:weighted_average_latency_ms], ' ms')} | #{format_optional(totals[:measured_token_coverage_pct], '%')} | #{format_cost(totals)} |"
      lines << ''
      lines << "_Estimated from measured tokens and Cloudflare rates verified #{report[:pricing][:verified_on]}; not invoice or credit truth._"
      lines << "_Inference quality is unknown; SaneCite canaries and product benchmarks are separate and were not run by this report._"
      report[:warnings].each { |warning| lines << "- Warning: #{warning}" }
      lines << ''
      lines << '---'
      lines.join("\n")
    end

    def row_value(row, key)
      row[key] || row[key.to_sym]
    end

    def finite_number(value)
      raise ArgumentError, 'missing required meter aggregate' if value.nil? || value == ''

      number = Float(value)
      raise ArgumentError, 'non-finite meter value' unless number.finite? && number >= 0

      number
    end

    def quality_code(value)
      raise ArgumentError, 'missing required quality code' if value.nil? || value == ''

      number = Integer(value)
      raise ArgumentError, 'inference quality must remain unknown' unless number == -1

      number
    end

    def inference_quality_status
      {
        state: 'unknown',
        source: 'inference_meter_only',
        note: 'SaneCite canaries and product benchmarks are separate sources and were not run by this report.'
      }
    end

    def parse_ai_meter_time(value)
      return nil if value.to_s.empty?

      timestamp = value.to_s.strip
      timestamp = "#{timestamp}Z" unless timestamp.match?(/(?:Z|[+-]\d{2}:?\d{2})\z/i)
      Time.parse(timestamp).utc.iso8601
    rescue ArgumentError
      nil
    end

    def round_count(value)
      rounded = value.round
      (value - rounded).abs < 0.000_001 ? rounded : value.round(3)
    end

    def format_optional(value, suffix)
      value.nil? ? 'unavailable' : "#{value}#{suffix}"
    end

    def format_cost(summary)
      value = summary[:gross_post_credit_estimated_usd]
      value.nil? ? summary[:cost_state] : format('$%.6f (%s)', value, summary[:cost_state])
    end
  end
end
