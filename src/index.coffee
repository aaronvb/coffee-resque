exports.version = '0.1.4'

# Sets up a new Resque Connection.  This Connection can either be used to
# queue new Resque jobs, or be passed into a worker through a `connection`
# option.
#
# options - Optional Hash of options.
#           redis     - An existing redis connection to use.
#           host      - String Redis host.  (Default: Redis' default)
#           port      - Integer Redis port.  (Default: Redis' default)
#           password  - String Redis password.
#           namespace - String namespace prefix for Redis keys.
#                       (Default: resque).
#           callbacks - Object containing defined job functions.
#           timeout   - Integer timeout in milliseconds to pause polling if
#                       the queue is empty.
#           database  - Integer of the Redis database to select.
#
# Returns a Connection instance.
exports.connect = (options) ->
  new exports.Connection options || {}

EventEmitter = require('events').EventEmitter

# Handles the connection to the Redis server.  Connections also spawn worker
# instances for processing jobs.
class Connection
  constructor: (options) ->
    @redis     = options.redis     || connectToRedis options
    @namespace = options.namespace || 'resque'
    @callbacks = options.callbacks || {}
    @timeout   = options.timeout   || 5000
    @redis.select options.database if options.database?

  # Public: Queues a job in a given queue to be run.
  #
  # queue - String queue name.
  # func  - String name of the function to run.
  # args  - Optional Array of arguments to pass.
  #
  # Returns nothing.
  enqueue: (queue, func, args) ->
    @redis.sadd  @key('queues'), queue
    @redis.rpush @key('queue', queue),
      JSON.stringify class: func, args: args || []

  # Public: Creates a single Worker from this Connection.
  #
  # queues    - Either a comma separated String or Array of queue names.
  # callbacks - Optional Object that has the job functions defined.  This will
  #             be taken from the Connection by default.
  #
  # Returns a Worker instance.
  worker: (queues, callbacks) ->
    new exports.Worker @, queues, callbacks or @callbacks

  # Public: Quits the connection to the Redis server.
  #
  # Returns nothing.
  end: ->
    @redis.quit()

  # Builds a namespaced Redis key with the given arguments.
  #
  # args - Array of Strings.
  #
  # Returns an assembled String key.
  key: (args...) ->
    args.unshift @namespace
    args.join ":"

# Handles the queue polling and job running.
#
# Emits 'poll' each time Redis is checked.
#   err    - The caught exception.
#   worker - This Worker instance.
#   queue  - The String queue that is being checked.
#
# Emits 'job' before attempting to run any job.
#   worker - This Worker instance.
#   queue  - The String queue that is being checked.
#   job    - The parsed Job object that was being run.
#
# Emits 'success' after a successful job completion.
#   worker - This Worker instance.
#   queue  - The String queue that is being checked.
#   job    - The parsed Job object that was being run.
#   result - The result produced by the job.
#
# Emits 'error' if there is an error fetching or running the job.
#   err    - The caught exception.
#   worker - This Worker instance.
#   queue  - The String queue that is being checked.
#   job    - The parsed Job object that was being run.
#
# Returns nothing.
class Worker extends EventEmitter
  # See Connection#worker
  constructor: (connection, queues, callbacks) ->
    @conn      = connection
    @redis     = connection.redis
    @queues    = queues
    @callbacks = callbacks or {}
    @running   = false
    @shutdown  = false
    @ready     = false
    @checkQueues()
    @prune_dead_workers()

  # Public: Tracks the worker in Redis and starts polling.
  #
  # Returns nothing.
  start: ->
    if @ready
      @register_signal_handlers()
      @init => @poll()
    else
      @running = true

  # Public: Stops polling and purges this Worker's stats from Redis.
  #
  # cb - Optional Function callback.
  #
  # Returns nothing.
  end: (cb) ->
    @running = false
    @untrack()
    @redis.del [
      @conn.key('worker', @name, 'started')
      @conn.key('stat', 'failed', @name)
      @conn.key('stat', 'processed', @name)
    ], cb

  # Exit will run end, cleaning up resque, then either kill the process or
  # set the shutdown variable to true, allowing the current job to finish
  # and killing the process on next poll.
  #
  # Returns nothing.
  exit: (kill) ->
    @end()
    if kill
      process.exit()
    else
      @shutdown = true

  # Register Signal Handlers
  #
  # SIGINT: Exit immediately, stop processing jobs
  # SIGTERM: Exit immediately, stop processing jobs
  # SIGQUIT: Shutdown on next poll, or after current job is finished
  #
  # Returns nothing.
  register_signal_handlers: ->
    process.on 'SIGINT', () =>
      @exit(true)
    process.on 'SIGTERM', () =>
      @exit(true)
    process.on 'SIGQUIT', () =>
      @exit(false)

  # PRIVATE METHODS

  # Polls the next queue for a job.
  #
  # title - The title to set on the running process (optional).
  #
  # Returns nothing.
  poll: (title) ->
    process.exit() if @shutdown
    return unless @running
    process.title = title if title
    @queue = @queues.shift()
    @queues.push @queue
    @emit 'poll', @, @queue
    @redis.lpop @conn.key('queue', @queue), (err, resp) =>
      if !err && resp
        @work JSON.parse(resp.toString())
      else
        @emit 'error', err, @, @queue if err
        @pause()

  # Processed a job
  #
  # Returns nothing.
  perform: (job, old_title) ->
    if cb = @callbacks[job.class]
      cb job.args..., (result) =>
        try
          if result instanceof Error
            @fail result, job
          else
            @succeed result, job
        finally
          @poll old_title
    else
      @fail new Error("Missing Job: #{job.class}"), job
      @poll old_title

  # Handles the actual running of the job.
  #
  # job - The parsed Job object that is being run.
  #
  # Returns nothing.
  work: (job) ->
    old_title = process.title
    @emit 'job', @, @queue, job
    @procline "#{@queue} job since #{(new Date).toString()}"
    @perform(job, old_title)
  # Tracks stats for successfully completed jobs.
  #
  # result - The result produced by the job. 
  # job    - The parsed Job object that is being run.
  #
  # Returns nothing.
  succeed: (result, job) ->
    @redis.incr @conn.key('stat', 'processed')
    @redis.incr @conn.key('stat', 'processed', @name)
    @emit 'success', @, @queue, job, result

  # Tracks stats for failed jobs, and tracks them in a Redis list.
  #
  # err - The caught Exception.
  # job - The parsed Job object that is being run.
  #
  # Returns nothing.
  fail: (err, job) ->
    @redis.incr  @conn.key('stat', 'failed')
    @redis.incr  @conn.key('stat', 'failed', @name)
    @redis.rpush @conn.key('failed'),
      JSON.stringify(@failurePayload(err, job))
    @emit 'error', err, @, @queue, job

  # Pauses polling if no jobs are found.  Polling is resumed after the timeout
  # has passed.
  #
  # Returns nothing.
  pause: ->
    @procline "Sleeping for #{@conn.timeout/1000}s"
    setTimeout =>
      process.exit() if @shutdown
      return if !@running
      @track()
      @poll()
    , @conn.timeout

  # Tracks this worker's name in Redis.
  #
  # Returns nothing.
  track: ->
    @running = true
    @redis.sadd @conn.key('workers'), @name

  # Removes this worker's name from Redis.
  #
  # Returns nothing.
  untrack: ->
    @redis.srem @conn.key('workers'), @name

  # Initializes this Worker's start date in Redis.
  #
  # Returns nothing.
  init: (cb) ->
    @track()
    args = [@conn.key('worker', @name, 'started'), (new Date).toString()]
    @procline "Processing #{@queues.toString} since #{args.last}"
    args.push cb if cb
    @redis.set args...

  # Ensures that the given @queues value is in the right format.
  #
  # Returns nothing.
  checkQueues: ->
    return if @queues.shift?
    if @queues == '*'
      @redis.smembers @conn.key('queues'), (err, resp) =>
        @queues = if resp then resp.sort() else []
        @ready  = true
        @name   = @_name
        @start() if @running
    else
      @queues = @queues.split(',')
      @ready  = true
      @name   = @_name
  
  # Checks for dead workers
  # 
  # Returns nothing.
  prune_dead_workers: ->
    @find_running_workers_in_linux()
  
  # Finds and removes dead workers from redis queue
  
  # Returns nothing.
  find_workers_in_queue: (running_workers) ->
    @redis.smembers @conn.key('workers'), (err, resp) =>
      for worker in resp
        unless worker == @name # don't remove this process
          if running_workers.indexOf(worker.split(":")[1]) == -1
            @redis.srem @conn.key('workers'), worker # remove worker from queue if it isn't running
  
  # Finds all running resque workers, then passes array to find_workers_in_queue
  #
  # Returns nothing.
  find_running_workers_in_linux: ->
    util = require('util')
    exec = require('child_process').exec
    child = exec 'ps -A -o pid,command | grep "[r]esque" | grep -v "resque-web"', (error, stdout, stderr) =>
      running_workers = []
      for resque_process in stdout.split("\n")
        running_workers.push resque_process.split(" ")[0] unless resque_process == ""
      @find_workers_in_queue(running_workers)
  # Sets the process title.
  #
  # msg - The String message for the title.
  #
  # Returns nothing.
  procline: (msg) ->
    process.title = "resque-#{exports.version}: #{msg}"

  # Builds a payload for the Resque failed list.
  #
  # err - The caught Exception.
  # job - The parsed Job object that is being run.
  #
  # Returns a Hash.
  failurePayload: (err, job) ->
    worker:    @name
    queue:     @queue
    payload:   job
    exception: 'Error'
    error:     err.toString()
    backtrace: err.stack.split('\n')[1...]
    failed_at: (new Date).toString()

  Object.defineProperty @prototype, 'name',
    get: -> @_name
    set: (name) ->
      @_name = if @ready
        [name or 'node', process.pid, @queues].join(":")
      else
        name

connectToRedis = (options) ->
  redis = require('redis').createClient options.port, options.host
  redis.auth options.password if options.password?
  redis

exports.Connection = Connection
exports.Worker     = Worker
