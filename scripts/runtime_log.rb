#!/usr/bin/env ruby
# frozen_string_literal: true

# Shared app-runtime log owner. Uses the shared Ruby script scaffold and stdlib;
# the supervisor owns only its log child, never the customer app.
require 'fileutils'
require 'json'
require 'tmpdir'
require 'time'
require 'shellwords'

class SaneRuntimeLog
  attr_reader :path, :receipt_path, :pid

  def self.duration(args)
    index = args.index('--log-seconds')
    value = index ? Float(args.fetch(index + 1)) : 1800.0
    raise ArgumentError, '--log-seconds must be between 0 and 21600' unless value.positive? && value <= 21_600
    value
  rescue IndexError, TypeError
    raise ArgumentError, '--log-seconds requires a number'
  end

  def initialize(project_dir:, app_name:, seconds: 1800, subsystem: nil, command: nil, startup_seconds: 5)
    raise ArgumentError, 'invalid log duration' unless seconds.positive? && seconds <= 21_600
    root = File.join(project_dir, 'outputs', 'runtime-logs')
    FileUtils.mkdir_p(root)
    @dir = Dir.mktmpdir("#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-", root)
    @path = File.join(@dir, 'live.log')
    @receipt_path = File.join(@dir, 'receipt.json')
    @seconds, @startup_seconds = seconds, startup_seconds
    predicate = "process == #{JSON.generate(app_name)}"
    predicate += " OR subsystem BEGINSWITH #{JSON.generate(subsystem)}" if subsystem
    @command = command || ['/usr/bin/log', 'stream', '--predicate', predicate, '--level', 'debug',
                           '--style', 'compact', '--timeout', seconds.ceil.to_s]
    @receipt = { app: app_name, log_path: @path, started_at: Time.now.utc.iso8601(6),
                 max_seconds: seconds, state: 'starting', launcher_pid: Process.pid,
                 lifecycle: 'original launched PIDs only; a relaunch requires a new capture' }
  end

  def start
    reader, @control = IO.pipe
    @pid = fork do
      @control.close
      Process.setsid
      STDIN.reopen(File::NULL)
      STDOUT.reopen(File::NULL, 'w')
      STDERR.reopen(File::NULL, 'w')
      supervise(reader)
      exit! 0
    end
    reader.close
    @wait = Process.detach(@pid)
    deadline = monotonic + @startup_seconds + 1
    loop do
      receipt = read_receipt
      return self if receipt['state'] == 'recording'
      raise "Live log failed before launch: #{receipt['error'] || receipt['state']} (#{@path})" if %w[failed stopped].include?(receipt['state']) || !@wait.alive?
      raise "Live log readiness timed out: #{@path}" if monotonic >= deadline
      sleep 0.05
    end
  rescue Exception
    stop
    raise
  end

  def launched!(pids)
    pids = pids.map(&:to_i).select(&:positive?).uniq
    raise 'Live log cannot track an app without its launch PID' if pids.empty?
    raise "Live log stopped during launch: #{@path}" unless @wait.alive? && read_receipt['state'] == 'recording'
    @control.puts(JSON.generate(pids: pids))
    @control.flush
    self
  end

  def detach
    @control.close unless @control.closed?
    puts "Live log: #{@path} (saved until launched app exits or #{@seconds}s deadline)"
    puts "Stop capture: ruby #{Shellwords.escape(__FILE__)} stop #{Shellwords.escape(@receipt_path)}"
    self
  end

  def follow(output = $stdout)
    File.open(@path) do |file|
      loop do
        output.write(file.read.to_s)
        output.flush
        break unless @wait.alive?
        sleep 0.1
      end
      output.write(file.read.to_s)
    end
    receipt = read_receipt
    raise "Live log failed during runtime: #{receipt['error']} (#{@path})" if receipt['state'] == 'failed'
  ensure
    stop
  end

  def stop
    File.write(File.join(@dir, 'stop'), '') if @wait&.alive?
    unless @control.nil? || @control.closed?
      @control.puts(JSON.generate(stop: true))
      @control.close
    end
    @wait&.join(4)
  rescue Errno::EPIPE, IOError
    @wait&.join(4)
  end

  private

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def read_receipt
    JSON.parse(File.read(@receipt_path))
  rescue Errno::ENOENT
    {}
  end

  def save_receipt
    tmp = "#{@receipt_path}.tmp"
    File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |f| f.write(JSON.pretty_generate(@receipt)) }
    File.rename(tmp, @receipt_path)
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def supervise(control)
    Process.setpriority(Process::PRIO_PROCESS, 0, 10)
    %w[TERM INT HUP].each { |signal| Signal.trap(signal) { @stop_reason = "signal_#{signal}" } }
    @receipt[:supervisor_pid] = Process.pid
    started = monotonic
    output = File.open(@path, File::WRONLY | File::CREAT | File::EXCL, 0o600)
    log_pid = Process.spawn(*@command, out: output, err: output, pgroup: true)
    output.close
    @receipt[:log_pid] = log_pid
    save_receipt
    pids = nil
    child_reaped = false
    loop do
      if Process.waitpid(log_pid, Process::WNOHANG)
        child_reaped = true
        raise 'log stream exited before launch readiness' if @receipt[:state] == 'starting'
        if monotonic - started < @seconds - 0.1 && (!pids || pids.any? { |pid| alive?(pid) })
          raise 'log stream exited while runtime capture was required'
        end
        @stop_reason = 'log_stream_exited'
      end
      if @receipt[:state] == 'starting'
        # Apple's compact stream emits this header after installing its filter.
        if File.read(@path, 4096).to_s.include?('Filtering the log data using')
          @receipt[:state] = 'recording'
          @receipt[:ready_at] = Time.now.utc.iso8601(6)
          save_receipt
        elsif monotonic - started >= @startup_seconds
          raise 'log stream did not acknowledge its filter before startup deadline'
        end
      end
      @stop_reason ||= 'app_exited' if pids && pids.none? { |pid| alive?(pid) }
      @stop_reason ||= 'deadline' if monotonic - started >= @seconds
      @stop_reason ||= 'stop_requested' if File.exist?(File.join(@dir, 'stop'))
      break if @stop_reason
      if control && IO.select([control], nil, nil, 0.1)
        line = control.gets
        if line
          message = JSON.parse(line)
          @stop_reason = 'stop_requested' if message['stop']
          if message['pids']
            pids = message['pids']
            @receipt[:app_pids] = pids
            @receipt[:launch_confirmed_at] = Time.now.utc.iso8601(6)
            save_receipt
          end
        else
          control.close
          control = nil
          @stop_reason = 'launcher_exited_before_launch' unless pids
        end
      elsif !control
        sleep 0.1
      end
    end
  rescue Exception => e
    @receipt[:state] = 'failed'
    @receipt[:error] = "#{e.class}: #{e.message}"
  ensure
    if log_pid && !child_reaped
      Process.kill('TERM', -log_pid) rescue nil
      deadline = monotonic + 1
      until Process.waitpid(log_pid, Process::WNOHANG)
        if monotonic >= deadline
          Process.kill('KILL', -log_pid) rescue nil
          Process.waitpid(log_pid)
          break
        end
        sleep 0.05
      end
    end
    @receipt[:state] = 'stopped' unless @receipt[:state] == 'failed'
    @receipt[:stop_reason] = @stop_reason
    @receipt[:stopped_at] = Time.now.utc.iso8601(6)
    save_receipt
    control&.close
  end
end

if __FILE__ == $PROGRAM_NAME
  abort 'Usage: ruby runtime_log.rb stop RECEIPT_PATH' unless ARGV.length == 2 && ARGV.first == 'stop'
  receipt = File.expand_path(ARGV.last)
  JSON.parse(File.read(receipt)).fetch('supervisor_pid')
  File.write(File.join(File.dirname(receipt), 'stop'), '')
end
