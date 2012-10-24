namespace :profile do

  require 'fileutils'
  require 'flapjack/configuration'

  FLAPJACK_ROOT   = File.join(File.dirname(__FILE__), '..')
  FLAPJACK_CONFIG = File.join(FLAPJACK_ROOT, 'etc', 'flapjack_config.yaml')

  FLAPJACK_PROFILER = ENV['FLAPJACK_PROFILER'] || 'rubyprof'
  port = ENV['FLAPJACK_PROFILER'].to_i
  FLAPJACK_PORT = ((port > 1024) && (port <= 65535)) ? port : 8075

  REPETITIONS     = 100

  # If this is higher than 30 I'm getting "stack level too deep" errors for that part
  RESQUE_REPETITIONS = 30

  require (FLAPJACK_PROFILER =~ /^perftools$/i) ? 'perftools' : 'ruby-prof'

  def profile_coordinator(config, redis_options)
    # redis = Redis.new(redis_options.merge(:driver => 'ruby'))
    # check_db_empty(:redis => redis, :redis_options => redis_options)
    # setup_baseline_data(:redis => redis)

    # coordinator = Flapjack::Coordinator.new(config, redis_options)

    # profile('coordinator') {
    #   coordinator.start(:daemonize => false, :signals => false)
    # }

    # yield if block_given?

    # coordinator.stop
    # empty_db(:redis => redis)
    # redis.quit
  end

  def profile_pikelet(klass, name, config, redis_options)
    redis = Redis.new(redis_options.merge(:driver => 'ruby'))
    check_db_empty(:redis => redis, :redis_options => redis_options)
    setup_baseline_data(:redis => redis)

    EM.synchrony do
      pikelet = klass.new
      pikelet.bootstrap(:config => config,
        :redis_config => redis_options)

      extern_thr = Thread.new {
        Thread.stop
        yield if block_given?
        pikelet.stop
        pikelet.add_shutdown_event(:redis => redis)
      }

      profile_fib = profile_fiber(name, extern_thr) {
        pikelet.main
      }
      profile_fib.resume

      extern_thr.run
      extern_thr.join

      are_we_there_yet?(profile_fib) {
        pikelet.cleanup
      }
    end

    empty_db(:redis => redis)
    redis.quit
  end

  def profile_resque(klass, name, config, redis_options)
    redis = Redis.new(redis_options.merge(:driver => 'ruby'))
    check_db_empty(:redis => redis, :redis_options => redis_options)
    setup_baseline_data(:redis => redis)

    ::Resque.redis = redis

    EM.synchrony do

      worker = EM::Resque::Worker.new(config['queue'])

      extern_thr = Thread.new {
        yield if block_given?
      }

      profile_fib = profile_fiber(name, extern_thr) {
        worker.work(0.1) {|job|
          @profiler_count ||= 0
          @profiler_count += 1
          if @profiler_count >= RESQUE_REPETITIONS
            job.worker.shutdown
          end
        }
      }

      extern_thr.join

      profile_fib.resume

      are_we_there_yet?(profile_fib) {}
    end

    empty_db(:redis => redis)
    redis.quit
  end

  def profile_thin(klass, name, config, redis_options, &block)
    redis = Redis.new(redis_options.merge(:driver => 'ruby'))
    check_db_empty(:redis => redis, :redis_options => redis_options)
    setup_baseline_data(:redis => redis)

    Thin::Logging.silent = true

    EM.synchrony do

      klass.bootstrap(:config => config, :redis_config => redis_options)

      profile(name) {
        server = Thin::Server.new('0.0.0.0', FLAPJACK_PORT,
          klass, :signals => false)

        server.start

        EM.defer(block, proc {
          server.stop!
          Fiber.new {
            klass.cleanup
          }
          EM.stop
        })
      }
    end

    empty_db(:redis => redis)
    redis.quit
  end

  ### utility methods

  def load_config
    config_env, redis_options = Flapjack::Configuration.new.
                                  load(FLAPJACK_CONFIG)
    if config_env.nil? || config_env.empty?
      puts "No config data for environment '#{FLAPJACK_ENV}' " +
        "found in '#{FLAPJACK_CONFIG}'"
      exit(false)
    end

    return config_env, redis_options
  end

  def check_db_empty(options = {})
    redis = options[:redis]
    redis_options = options[:redis_options]

    # DBSIZE can return > 0 with expired keys -- but that's fine, we only
    # want to run against an explicitly empty DB. If this fails against the
    # intended Redis DB, the user can FLUSHDB it manually
    db_size = redis.dbsize.to_i
    if db_size > 0
      db = redis_options['db']
      puts "The Redis database has a non-zero DBSIZE (#{db_size}) -- "
           "profiling will destroy data. Use 'SELECT #{db}; FLUSHDB' in " +
           'redis-cli if you want to profile using this database.'
      puts "[redis options] #{options[:redis].inspect}\nExiting..."
      exit(false)
    end
  end

  # this adds a default entity and contact, so that the profiling methods
  # will actually trigger enough code to be useful
  def setup_baseline_data(options = {})
    entity = {"id"        => "2000",
              "name"      => "clientx-app-01",
              "contacts"  => ["1000"]}

    Flapjack::Data::Entity.add(entity, :redis => options[:redis])

    contact = {'id'         => '1000',
               'first_name' => 'John',
               'last_name'  => 'Smith',
               'email'      => 'jsmith@example.com',
               'media'      => {
                 'email' => 'jsmith@example.com'
               }}

    Flapjack::Data::Contact.add(contact, :redis => options[:redis])
  end

  def empty_db(options = {})
    redis = options[:redis]
    redis.flushdb
  end

  def profile_fiber(name, thread = nil, &block)
    output_dir = File.join('tmp', "profiles")
    FileUtils.mkdir_p(output_dir)
    Fiber.new {
      if FLAPJACK_PROFILER =~ /^perftools$/i
        PerfTools::CpuProfiler.start(output_filename) do
          block.call if block
        end
      else
        RubyProf::exclude_threads = [thread] if thread
        result = RubyProf.profile do
          block.call if block
        end
        result.eliminate_methods!([/Thread#join/])
        printer = RubyProf::MultiPrinter.new(result)
        printer.print(:path => output_dir, :profile => name)
      end
    }
  end

  def profile(name, &block)
    output_dir = File.join('tmp', "profiles")
    FileUtils.mkdir_p(output_dir)
    if FLAPJACK_PROFILER =~ /^perftools$/i
      PerfTools::CpuProfiler.start(output_filename) do
        block.call if block
      end
    else
      result = RubyProf.profile do
        block.call if block
      end
      printer = RubyProf::MultiPrinter.new(result)
      printer.print(:path => output_dir, :profile => name)
    end
  end

  # if you ask often enough, eventually you'll get the reply you want
  def are_we_there_yet?(fib)
    loop do
      if fib.alive?
        EM::Synchrony.sleep 0.25
      else
        yield if block_given?
        EM.stop
        break
      end
    end
  end

  ## end utility methods

  desc "profile startup of running through coordinator with rubyprof"
  task :coordinator do

    require 'flapjack/coordinator'

    require 'flapjack/data/entity'
    require 'flapjack/data/contact'

    FLAPJACK_ENV = ENV['FLAPJACK_ENV'] || 'profile'
    config_env, redis_options = load_config
    profile_coordinator(config_env, redis_options)
  end

  desc "profile executive with rubyprof"
  task :executive do

    require 'flapjack/executive'
    require 'flapjack/data/event'

    FLAPJACK_ENV = ENV['FLAPJACK_ENV'] || 'profile'
    config_env, redis_options = load_config
    profile_pikelet(Flapjack::Executive, 'executive', config_env['executive'],
      redis_options) {

      # this executes in a separate thread, so no Fibery stuff is allowed
      redis = Redis.new(redis_options.merge(:driver => 'ruby'))

      REPETITIONS.times do |n|
        Flapjack::Data::Event.add({'entity'  => 'clientx-app-01',
                                   'check'   => 'ping',
                                   'type'    => 'service',
                                   'state'   => (n ? 'ok' : 'critical'),
                                   'summary' => 'testing'},
                                  :redis => redis)
      end
      redis.quit
    }
  end

  # NB: you'll need to access a real jabber server for this; if external events
  # come in from that then runs will not be comparable
  desc "profile jabber gateway with rubyprof"
  task :jabber do

    require 'flapjack/jabber'
    require 'flapjack/data/contact'
    require 'flapjack/data/event'
    require 'flapjack/data/notification'

    FLAPJACK_ENV = ENV['FLAPJACK_ENV'] || 'profile'
    config_env, redis_options = load_config
    profile_pikelet(Flapjack::Jabber, 'jabber', config_env['jabber_gateway'],
      redis_options) {

        # this executes in a separate thread, so no Fibery stuff is allowed
        redis = Redis.new(redis_options.merge(:driver => 'ruby'))

        event = Flapjack::Data::Event.new('type'    => 'service',
                                          'state'   => 'critical',
                                          'summary' => '100% packet loss',
                                          'entity'  => 'clientx-app-01',
                                          'check'   => 'ping')
        notification = Flapjack::Data::Notification.for_event(event)

        contact = Flapjack::Data::Contact.find_by_id('1000', :redis => redis)

        REPETITIONS.times do |n|
          notification.messages(:contacts => [contact]).each do |msg|
            contents = msg.contents
            contents['event_count'] = n
            redis.rpush(config_env['jabber_gateway']['queue'],
              Yajl::Encoder.encode(contents))
          end
        end

        redis.quit
    }
  end

  # NB: you'll need an external email server set up for this (whether it's
  # mailtrap or a real server)
  desc "profile email notifier with rubyprof"
  task :email do

    require 'eventmachine'
    # the redis/synchrony gems need to be required in this particular order, see
    # the redis-rb README for details
    require 'hiredis'
    require 'em-synchrony'
    require 'redis/connection/synchrony'
    require 'redis'
    require 'em-resque'
    require 'em-resque/worker'

    require 'flapjack/patches'
    require 'flapjack/redis_pool'
    require 'flapjack/notification/email'

    require 'flapjack/data/contact'
    require 'flapjack/data/event'
    require 'flapjack/data/notification'

    FLAPJACK_ENV = ENV['FLAPJACK_ENV'] || 'profile'
    config_env, redis_options = load_config
    profile_resque(Flapjack::Notification::Email, 'email',
      config_env['email_notifier'], redis_options) {

      # this executes in a separate thread, so no Fibery stuff is allowed
      redis = Redis.new(redis_options.merge(:driver => 'ruby'))

      event = Flapjack::Data::Event.new('type'    => 'service',
                                        'state'   => 'critical',
                                        'summary' => '100% packet loss',
                                        'entity'  => 'clientx-app-01',
                                        'check'   => 'ping')
      notification = Flapjack::Data::Notification.for_event(event)

      contact = Flapjack::Data::Contact.find_by_id('1000', :redis => redis)

      REPETITIONS.times do
        notification.messages(:contacts => [contact]).each do |msg|
          Resque.enqueue_to(config_env['email_notifier']['queue'],
            Flapjack::Notification::Email, msg.contents)
        end
      end

      redis.quit
    }
  end

  # Of course, if external requests come to this server then different runs will
  # not be comparable
  desc "profile web server with rubyprof"
  task :web do

    require "net/http"
    require "uri"

    require 'flapjack/web'

    FLAPJACK_ENV = ENV['FLAPJACK_ENV'] || 'profile'
    config_env, redis_options = load_config
    profile_thin(Flapjack::Web, 'web', config_env['web'], redis_options) {
      uri = URI.parse("http://127.0.0.1:#{FLAPJACK_PORT}/")

      http = Net::HTTP.new(uri.host, uri.port)

      REPETITIONS.times do |n|
        request = Net::HTTP::Get.new(uri.request_uri)

        response = http.request(request)
        # puts "#{n} #{response.body}"
      end
    }
  end

end