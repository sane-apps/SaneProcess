# frozen_string_literal: true

module SaneSOPScore
  module_function

  def base_score(block_count)
    case block_count.to_i
    when 0 then 10
    when 1..2 then 9
    when 3..4 then 8
    when 5..7 then 7
    when 8..10 then 6
    else 5
    end
  end

  def verification_cap(verify_status)
    attempts = verify_status[:attempts].to_i
    return nil if attempts.zero?

    return { score: 6, reason: 'unrecovered_verify_failure' } unless verify_status[:last_success]
    zero_test_success = verify_status.key?(:last_tests_run) && verify_status[:last_tests_run].to_i.zero?
    if zero_test_success || verify_status[:last_evidence_strength].to_s == 'build_only'
      return { score: 8, reason: 'zero_test_success_weak_evidence' }
    end
    return { score: 8, reason: 'recovered_verify_failure' } if verify_status[:failures].to_i.positive?

    nil
  end

  def score(block_count:, verify_status: {})
    base = base_score(block_count)
    cap = verification_cap(symbolize_keys(verify_status || {}))
    final = cap ? [base, cap[:score]].min : base
    {
      score: final,
      base_score: base,
      block_count: block_count.to_i,
      cap_score: cap && cap[:score],
      cap_reason: cap && cap[:reason]
    }
  end

  def symbolize_keys(hash)
    hash.each_with_object({}) do |(key, value), memo|
      memo[key.to_sym] = value
    end
  end
end
