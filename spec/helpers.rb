require "rspec"
require "eventmachine"
require "em-http-request"
require "uuidtools"
require "multi_json"

module Helpers
  def setup_options
    @options = {
      :config_file => File.join(File.dirname(__FILE__), "config.json"),
      :config_dirs => [File.join(File.dirname(__FILE__), "conf.d")],
      :extension_dir => File.join(File.dirname(__FILE__), "extensions"),
      :log_level => :fatal
    }
  end

  def options
    @options ? @options : setup_options
  end

  def setup_redis
    @redis = EM::Protocols::Redis.connect
  end

  def redis
    @redis ? @redis : setup_redis
  end

  def setup_transport
    @transport = Sensu::Transport.connect("rabbitmq", {})
  end

  def transport
    @transport ? @transport : setup_transport
  end

  def keepalive_queue(&callback)
    transport.subscribe(:direct, "keepalives", "keepalives") do |_, payload|
      callback.call(payload)
    end
  end

  def result_queue(&callback)
    transport.subscribe(:direct, "results", "results") do |_, payload|
      callback.call(payload)
    end
  end

  def timer(delay, &callback)
    periodic_timer = EM::PeriodicTimer.new(delay) do
      callback.call
      periodic_timer.cancel
    end
  end

  def async_wrapper(&callback)
    EM::run do
      timer(15) do
        raise "test timed out"
      end
      callback.call
    end
  end

  def async_done
    EM::stop_event_loop
  end

  def api_test(&callback)
    async_wrapper do
      Sensu::API::Process.test(options)
      timer(0.5) do
        callback.call
      end
    end
  end

  def with_stdout_redirect(&callback)
    stdout = STDOUT.clone
    STDOUT.reopen(File.open("/dev/null", "w"))
    callback.call
    STDOUT.reopen(stdout)
  end

  def epoch
    Time.now.to_i
  end

  def client_template
    {
      :name => "i-424242",
      :address => "127.0.0.1",
      :subscriptions => [
        "test"
      ],
      :keepalive => {
        :thresholds => {
          :warning => 60,
          :critical => 120
        }
      }
    }
  end

  def check_template
    {
      :name => "test",
      :issued => epoch,
      :command => "echo WARNING && exit 1",
      :output => "WARNING",
      :status => 1,
      :executed => 1363224805
    }
  end

  def result_template(check_result = nil)
    {
      :client => "i-424242",
      :check => check_result || check_template
    }
  end

  def event_template
    client = client_template
    client[:timestamp] = epoch
    check = check_template
    check[:history] = [1]
    {
      :id => UUIDTools::UUID.random_create.to_s,
      :client => client,
      :check => check,
      :occurrences => 1,
      :action => :create
    }
  end

  def api_request(uri, method=:get, options={}, &callback)
    default_options = {
      :head => {
        :authorization => [
          "foo",
          "bar"
        ]
      }
    }
    request_options = default_options.merge(options)
    if request_options[:body].is_a?(Hash) || request_options[:body].is_a?(Array)
      request_options[:body] = MultiJson.dump(request_options[:body])
    end
    http = EM::HttpRequest.new("http://localhost:4567#{uri}").send(method, request_options)
    http.callback do
      body = case
      when http.response.empty?
        http.response
      else
        MultiJson.load(http.response)
      end
      callback.call(http, body)
    end
  end

  class TestServer < EM::Connection
    include RSpec::Matchers

    attr_accessor :expected

    def receive_data(data)
      if @expected
        expect(MultiJson.load(data)).to eq(MultiJson.load(@expected))
        EM::stop_event_loop
      end
    end
  end
end

RSpec::Matchers.define :contain do |callback|
  match do |actual|
    actual.any? do |item|
      callback.call(item)
    end
  end
end
