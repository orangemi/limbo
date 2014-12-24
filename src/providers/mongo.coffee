axon = require 'axon'
rpc = require 'axon-rpc'
limbo = require '../limbo'

rpcServerMap = {}
getRpcServer = (port) ->
  port = Number(port)
  arguments[0] = port
  unless rpcServerMap[port]
    rep = axon.socket 'rep'
    rpcServerMap[port] = server = new rpc.Server rep
    rep.bind.apply rep, arguments
  return rpcServerMap[port]

class Mongo

  constructor: (options) ->
    {conn, group, methods, statics, overwrites, schemas, rpcPort} = options
    @_group = group

    @_conn = conn
    @_methods = methods or {}
    @_statics = statics or {}
    @_overwrites = overwrites or {}
    @_rpcPort = rpcPort

    @_schemas = {}
    @_models = {}
    @loadSchemas schemas

  loadMethod: (name, fn, schemas) ->
    @_methods[name] = fn
    schema.methods[name] = fn for key, schema of schemas or @_schemas
    this

  loadStatic: (name, fn, schemas) ->
    @_statics[name] = fn
    schema.statics[name] = fn for key, schema of schemas or @_schemas
    this

  loadOverwrite: (name, overwriteMethod, models) ->
    @_overwrites[name] = overwriteMethod

    Object.keys(models or @_models).forEach (key) =>
      model = @_models[key]
      return unless typeof model[name] is 'function'
      _origin = model[name]
      _overwriteMethod = overwriteMethod(_origin)
      model[name] = -> _overwriteMethod.apply model, arguments

    this


  # Load mongoose schemas
  # @param `modelName` name of model, the first character is prefered uppercase
  # @param `schema` the mongoose schema instance
  # You can directly set an hash object to this method and it will
  # load all schemas in the object
  loadSchema: (modelName, schema) ->
    modelKey = modelName.toLowerCase()

    @_schemas[modelKey] = schema

    newSchemas = {}
    newSchemas[modelKey] = schema
    newModels = {}
    newModels[modelKey] = model

    @loadMethods @_methods, newSchemas
    @loadStatics @_statics, newSchemas

    model = @_conn.model modelName, schema

    @[modelKey] = model
    @[modelName + 'Model'] = model
    @_models[modelKey] = model

    @loadOverwrites @_overwrites, newModels

    @bindRpcEvent modelKey if @_rpcPort

    this

  # Alias of load prefixed methods
  loadMethods: (methods, schemas) ->
    @loadMethod(name, fn, schemas) for name, fn of methods
    this

  loadStatics: (statics, schemas) ->
    @loadStatic(name, fn, schemas) for name, fn of statics
    this

  loadOverwrites: (overwrites, models) ->
    @loadOverwrite(name, fn, models) for name, fn of overwrites
    this

  loadSchemas: (schemas) ->
    @loadSchema(modelName, schema) for modelName, schema of schemas
    this

  # Every model method will be exposed as 'group.model.method'
  # e.g. UserModel.findOne in group 'local' will be exposed as 'local.user.findOne'
  bindRpcEvent: (modelKey) ->
    server = getRpcServer @_rpcPort
    group = @_group
    models = @_models
    model = models[modelKey]

    # Bind rpc method and emit an event on each model when the callback be called
    # The pattern of event name is the method name
    # For example: db.user.on 'findOne', (err, user) ->
    _bindMethod = (methodName) ->
      eventName = "#{group}.#{modelKey}.#{methodName}"
      server.expose eventName, ->

        _emit = ->
          modelArgs = (v for k, v of arguments)
          modelArgs.unshift methodName
          model.emit.apply model, modelArgs

          # Emit wild broadcast message
          limboArgs = (v for k, v of arguments)
          limboArgs.unshift '*', eventName
          limbo.emit.apply limbo, limboArgs

        callback = arguments[arguments.length - 1]
        if typeof callback is 'function'
          _callback = =>
            _emit.apply this, arguments
            callback.apply this, arguments
          arguments[arguments.length - 1] = _callback
        else
          _callback = =>
            _emit.apply this, arguments
          arguments[arguments.length] = _callback

        # Call the query method
        model[methodName].apply model, arguments

    ignoredMethods = ['constructor']

    for methodName, method of model
      unless typeof method is 'function' and
             methodName.indexOf('_') isnt 0 and
             methodName not in ignoredMethods
        continue
      _bindMethod methodName

    this

module.exports = Mongo
