#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require 'json'
require 'open3'
require 'tmpdir'

include TestFramework

SCRIPT = File.expand_path('agentmemory-mcp-remote.sh', __dir__)

def bounded_capture(env, *args, seconds: 8, stdin_data: nil, close_stdin: true)
  Open3.popen3(env, *args, pgroup: true) do |input, output, error, waiter|
    input.write(stdin_data) if stdin_data
    input.close if close_stdin
    out = Thread.new { output.read }
    err = Thread.new { error.read }
    timed_out = false
    unless waiter.join(seconds)
      timed_out = true
      Process.kill('KILL', -waiter.pid) rescue Errno::ESRCH
      waiter.join
    end
    [out.value, err.value, waiter.value, timed_out]
  end
end

def write_exec(path, body)
  File.write(path, body)
  File.chmod(0o755, path)
end

exit(run_tests('AgentMemory MCP wrapper') do
  test_category('contract') do
    test('refuses Access URLs without --login') do
      _out, err, status, timed_out = bounded_capture({}, '/bin/zsh', SCRIPT, '--self-test')
      assert(!timed_out, 'self-test hung')
      assert(status.success?, err)
      assert_includes(err, 'self-test: pass')
      true
    end

    test('daily path uses the Mini worker, not cloud mcp-remote') do
      source = File.read(SCRIPT)
      assert_includes(source, 'agentmemory/health')
      assert_includes(source, 'mcp --no-engine')
      assert_includes(source, 'AGENTMEMORY_FORCE_PROXY=1')
      assert_includes(source, 'AGENTMEMORY_MCP_FORCE_CLOUD')
      assert(source.include?('exec_local_mcp'), 'local MCP exec missing')
      true
    end

    test('unhealthy worker fails fast instead of hanging on cloud mcp-remote') do
      Dir.mktmpdir('am-mcp-unhealthy') do |dir|
        curl = File.join(dir, 'curl')
        bin = File.join(dir, 'agentmemory')
        marker = File.join(dir, 'invoked')
        write_exec(curl, "#!/bin/sh\nexit 1\n")
        write_exec(bin, "#!/bin/sh\necho invoked > '#{marker}'\nexit 0\n")
        env = {
          'SANE_CURL_BIN' => curl,
          'AGENTMEMORY_BIN' => bin,
          'AGENTMEMORY_MCP_FORCE_CLOUD' => '0',
          'PATH' => "#{dir}:/usr/bin:/bin"
        }
        _out, err, status, timed_out = bounded_capture(env, '/bin/zsh', SCRIPT)
        assert(!timed_out, 'unhealthy path hung')
        assert_eq(status.exitstatus, 1)
        assert_includes(err, 'not healthy')
        assert(!File.exist?(marker), 'must not start a cloud or local MCP when health fails')
        true
      end
    end

    test('healthy worker execs local mcp --no-engine with FORCE_PROXY') do
      Dir.mktmpdir('am-mcp-healthy') do |dir|
        curl = File.join(dir, 'curl')
        bin = File.join(dir, 'agentmemory')
        log = File.join(dir, 'log')
        write_exec(curl, "#!/bin/sh\nexit 0\n")
        write_exec(bin, <<~SH)
          #!/bin/sh
          printf 'args=%s\nurl=%s\nproxy=%s\n' "$*" "$AGENTMEMORY_URL" "$AGENTMEMORY_FORCE_PROXY" > '#{log}'
          exit 0
        SH
        env = {
          'SANE_CURL_BIN' => curl,
          'AGENTMEMORY_BIN' => bin,
          'AGENTMEMORY_URL' => 'http://127.0.0.1:3111',
          'PATH' => "#{dir}:/usr/bin:/bin"
        }
        _out, err, status, timed_out = bounded_capture(env, '/bin/zsh', SCRIPT)
        assert(!timed_out, 'healthy local exec hung')
        assert(status.success?, err)
        recorded = File.read(log)
        assert_includes(recorded, 'args=mcp --no-engine')
        assert_includes(recorded, 'url=http://127.0.0.1:3111')
        assert_includes(recorded, 'proxy=1')
        true
      end
    end
  end

  test_category('live Mini worker') do
    test('wrapper initialize against loopback AgentMemory returns tools capability') do
      live = Open3.capture2e('/usr/bin/curl', '--silent', '--fail', '--max-time', '2',
                             'http://127.0.0.1:3111/agentmemory/livez')
      assert(live.last.success?, 'Mini AgentMemory worker must be healthy for this live probe')
      payload = {
        jsonrpc: '2.0',
        id: 1,
        method: 'initialize',
        params: {
          protocolVersion: '2024-11-05',
          capabilities: {},
          clientInfo: { name: 'agentmemory-mcp-remote-test', version: '0' }
        }
      }.to_json
      stdin = "Content-Length: #{payload.bytesize}\r\n\r\n#{payload}"
      out, err, _status, _timed_out = bounded_capture({}, '/bin/zsh', SCRIPT, seconds: 8,
                                                       stdin_data: stdin, close_stdin: false)
      assert(out.include?('"name":"agentmemory"') || out.include?('"name": "agentmemory"'),
             "initialize missing serverInfo: stdout=#{out[0, 400]} stderr=#{err[0, 400]}")
      assert(out.include?('protocolVersion'), err)
      true
    end
  end
end)
