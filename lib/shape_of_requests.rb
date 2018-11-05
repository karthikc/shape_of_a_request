require "shape_of_requests/version"

module ShapeOfRequests

  class ApplicationController < ActionController::Base

    def instrument_start(klass, method_name)
      ActiveSupport::Notifications.instrument('start_important_method.active_model',
                                              class: klass.name,
                                              method: method_name)
    end
    def instrument_process(klass, method_name)
      ActiveSupport::Notifications.instrument('process_important_method.active_model',
                                              class: klass.name,
                                              method: method_name) do
        yield
      end
    end
  end

  IGNORED_CONTROLLERS = ['ReactController', 'Api::UsersController', 'Api::TranslationsController']

  def instrument_instance_method(klass, method_name)
    klass.class_eval "alias uninstrumented_#{method_name} #{method_name}"
    klass.class_eval do
      define_method(method_name) do |*args|
        result = nil
        display_id = self.try(:source_id) ? source_id : id
        details = {class: self.class.name, method: method_AWS_ACCESS_KEY_IDname, args: args, display_id: display_id}
        ActiveSupport::Notifications.instrument('start_important_method.active_model', details)
        ActiveSupport::Notifications.instrument('process_important_method.active_model', details) do
          result = send("uninstrumented_#{method_name}", *args)
        end
        result
      end
    end
  end

  def instrument_all_methods_in(klass)
    puts "\n****************************** Instrumenting the following methods in #{klass.name}"
    klass.instance_methods(false).each do |method_name|
      method_name = method_name.to_s
      next if method_name.start_with?('validate_associated_records_for_') || method_name.start_with?('autosave_associated_records_for_') ||
          method_name.start_with?('after_remove_for_') || method_name.start_with?('before_remove_for_') ||
          method_name.start_with?('before_add_for_') || method_name.start_with?('after_add_for_')
      puts "****************************** Instrumenting #{klass.name}##{method_name}"
      instrument_instance_method(klass, method_name)
    end
  end

  instrument_all_methods_in(Klass)
  instrument_all_methods_in(School)
  instrument_all_methods_in(SpringBoard::School)
  instrument_all_methods_in(User)
  instrument_all_methods_in(Reader::QuizAttempt)
  instrument_all_methods_in(Reader::QuestionAttempt)
  instrument_all_methods_in(Reader::SimpleQuiz)

  def logger
    @logger ||= Logger.new("#{Rails.root}/log/zoom.log")
  end

  def start_event(event_detail)
    Thread.current[:instrumented_events] ||= []
    Thread.current[:instrumented_events] << event_detail
  end

  def stop_event(event_detail)
    last_event = Thread.current[:instrumented_events].pop
    if event_detail != last_event
      logger.error "Event mismatch Last Event: #{last_event}. Currently completed event: #{event_detail}"
    end
  end

# def in_model_event?
#   return false if Thread.current[:instrumented_events].nil?
#   Thread.current[:instrumented_events].any? {|event| event.starts_with?('active_model:')}
# end
#
  def log_event(message)
    depth = Thread.current[:instrumented_events] ? Thread.current[:instrumented_events].size : 0
    indentation = "    " * depth
    logger.info "Zoom Track - #{indentation}#{message}"
  end

  def log_controller_event(event, suffix)
    unless IGNORED_CONTROLLERS.include?(event.payload[:controller])
      log_event("CONTROLLER #{event.payload[:method]} (#{event.payload[:format]}) #{event.payload[:controller]} #{event.payload[:action]}. #{suffix}")
    end
  end

  def log_queue_event(event, suffix)
    job = event.payload[:job]
    first_argument = job.arguments.first
    log_event("QUEUE #{job.queue_name}. With #{first_argument ? first_argument.to_s.truncate(50) : ''}. #{suffix}")
  end

  ActiveSupport::Notifications.subscribe "start_processing.action_controller" do |*args|
    event = ActiveSupport::Notifications::Event.new(*args)
    log_controller_event(event, "Start")
    start_event("action_controller:#{event.payload[:controller]}-#{event.payload[:action]}")
  end

  ActiveSupport::Notifications.subscribe "process_action.action_controller" do |*args|
    event = ActiveSupport::Notifications::Event.new(*args)
    stop_event("action_controller:#{event.payload[:controller]}-#{event.payload[:action]}")
    log_controller_event(event, "Done\n")
  end

  ActiveSupport::Notifications.subscribe "sql.active_record" do |*args|
    event = ActiveSupport::Notifications::Event.new(*args)
    if event.payload[:name] != 'SCHEMA' &&
        event.payload[:name] != 'CACHE' &&
        event.payload[:name] != 'Explain' &&
        !event.payload[:name].blank? &&
        !event.payload[:cached] &&
        # (in_model_event? || (!event.payload[:name].ends_with?(' Load') && !event.payload[:name].ends_with?(' Exists')))
        !event.payload[:name].ends_with?(' Load') &&
        !event.payload[:name].ends_with?(' Exists')
      log_event("#{event.payload[:name]} #{event.payload[:sql].truncate(60)}")
    end
  end

  ActiveSupport::Notifications.subscribe "start_important_method.active_model" do |*args|
    event = ActiveSupport::Notifications::Event.new(*args)
    # log_event("MODEL: #{event.payload[:class]} #{event.payload[:method]}. Start")
    log_event("MODEL: #{event.payload[:class]}(#{event.payload[:display_id]}) #{event.payload[:method]}")
    start_event("active_model:#{event.payload[:class]}-#{event.payload[:method]}")
  end

  ActiveSupport::Notifications.subscribe "process_important_method.active_model" do |*args|
    event = ActiveSupport::Notifications::Event.new(*args)
    stop_event("active_model:#{event.payload[:class]}-#{event.payload[:method]}")
    # log_event("MODEL: #{event.payload[:class]} #{event.payload[:method]}. Done")
  end

  ActiveSupport::Notifications.subscribe "enqueue.active_job" do |*args|
    event = ActiveSupport::Notifications::Event.new(*args)
    log_queue_event(event, "Added Job To Queue")
  end

  ActiveSupport::Notifications.subscribe "enqueue_at.active_job" do |*args|
    event = ActiveSupport::Notifications::Event.new(*args)
    log_queue_event(event, "Added Job To Queue")
  end

  ActiveSupport::Notifications.subscribe "perform_start.active_job" do |*args|
    event = ActiveSupport::Notifications::Event.new(*args)
    log_queue_event(event, "Started Job")
    start_event("active_job:#{event.payload[:job].job_id}")
  end

  ActiveSupport::Notifications.subscribe "perform.active_job" do |*args|
    event = ActiveSupport::Notifications::Event.new(*args)
    stop_event("active_job:#{event.payload[:job].job_id}")
    log_queue_event(event, "Done\n")
  end

end
