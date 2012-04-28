Tree =
  mkdir: (tree, path) ->
    for item in path
      tree = (tree[item] ||= {})
    tree

  cd: (tree, path) ->
    for item in path
      tree = tree?[item]
    tree

  set: (tree, path, value) ->
    [prefix..., suffix] = path
    Tree.mkdir(tree, prefix)[suffix] = value

  get: (tree, path, value) ->
    [prefix..., suffix] = path
    Tree.cd(tree, prefix)[suffix]

makeObject = (key, value) ->
  object = {}
  object[key] = value
  return object

splitSelector = (selector) ->
  if selector
    selector.split ' '
  else
    []


class UIControllerWrapper

  constructor: (@parent, @prefix, @controller) ->
    @controller.$ = @update.bind(@)
    @reversePrefix = @prefix.slice(0).reverse()

    @childControllers = {}
    @selectorsTestedForChildControllers = {}
    @_enqueuedPayload = {}
    @_updateNestingLevel = 0

    @name = (@parent && "#{@parent.name}/" || "") + @controller.constructor.name + (@prefix.length > 0 && "(#{@prefix.join(' ')})" || "")

  initialize: ->
    @rescan()
    @instantiateCoControllers()
    @controller.initialize()


  ################################################################################
  # outgoing payloads

  update: (payload) ->
    LR.log.fyi "update of #{@name}: " + JSON.stringify(payload, null, 2)
    @_sendUpdate payload, =>
      for own key, value of payload
        @instantiateChildControllers [key]

  _sendChildUpdate: (childWrapper, payload) ->
    LR.log.fyi "_sendChildUpdate from #{childWrapper.name} to #{@name}: " + JSON.stringify(payload, null, 2)
    @_sendUpdate payload

  _sendUpdate: (payload, func) ->
    # TODO: smarter merge (merge #smt and .smt keys, overwrite property keys)
    @_enqueuedPayload = Object.merge @_enqueuedPayload, payload, true
    LR.log.fyi "#{@name}._sendUpdate merged payload: " + JSON.stringify(@_enqueuedPayload, null, 2)

    if func
      @_updateNestingLevel++
      try
        func()
      finally
        @_updateNestingLevel--

    if @_updateNestingLevel == 0
      @_submitEnqueuedPayload()

  _submitEnqueuedPayload: ->
    LR.log.fyi "#{@name}._submitEnqueuedPayload: " + JSON.stringify(@_enqueuedPayload, null, 2)
    payload = @_enqueuedPayload
    @_enqueuedPayload = {}

    for key in @reversePrefix
      payload = makeObject(key, payload)
    @$ payload


  ################################################################################
  # child controllers

  instantiateCoControllers: ->
    LR.log.fyi "#{@name}.instantiateCoControllers(): " + JSON.stringify(Object.keys(@eventToSelectorToHandler['controller?'] || {}))
    for own selector, handler of @eventToSelectorToHandler['controller?'] || {}
      if selector.match /^%[a-zA-Z0-9-]+$/
        @instantiateChildController '', handler, selector

  addChildController: (selector, childController) ->
    LR.log.fyi "Adding a child controller for #{selector} of #{@name}"
    @childControllers[selector] = wrapper = new UIControllerWrapper(this, splitSelector(selector), childController)
    wrapper.$ = @_sendChildUpdate.bind(@, wrapper)
    LR.log.fyi "Initializing child controller #{wrapper.name}"
    wrapper.initialize()
    LR.log.fyi "Done adding child controller #{wrapper.name}"

  instantiateChildController: (selector, handler, handlerSpecSelector) ->
    LR.log.fyi "Instantiating a child controller for #{handlerSpecSelector}, actual selector '#{selector}'"
    if childController = handler.call(@controller)
      @addChildController selector, childController

  instantiateChildControllers: (path) ->
    childSelector = path.join(' ')
    if @selectorsTestedForChildControllers[childSelector]
      return
    @selectorsTestedForChildControllers[childSelector] = yes

    handlers = @collectHandlers @handlerTree, path, 'controller?'
    for { handler, selector } in handlers
      @instantiateChildController childSelector, handler, selector


  ################################################################################
  # incoming payloads

  notify: (payload, path=[]) ->
    if path.length == 0
      LR.log.fyi "Notification received: " + JSON.stringify(payload, null, 2)

    selector = path.join(' ')
    if childController = @childControllers[selector]
      LR.log.fyi "Handing payload off to a child controller for #{selector}"
      childController.notify(payload)

    for own key, value of payload
      if key[0] == '#'
        path.push key
        @notify value, path
        path.pop()
      else
        @invoke path, key, value,

  invoke: (path, event, arg) ->
    event = "#{event}!" unless event.match /[?!]$/

    LR.log.fyi "Looking for handlers for path #{path.join(' ')}, event #{event}"
    Function::toJSON = -> "<func>"
    LR.log.fyi "Handler tree: " + JSON.stringify(@handlerTree, null, 2)
    delete Function::toJSON

    handlers = @collectHandlers @handlerTree, path, event, '*' + event.match(/[?!]$/)[0]
    for { handler, selector } in handlers
      LR.log.fyi "Invoking handler for #{selector}"
      handler.call(@controller, arg, path, event)


  ################################################################################
  # selector/handler hookup

  collectHandlers: (node, path, event, wildcardEvent=null, handlers=[], selectorComponents=[]) ->
    LR.log.fyi "collectHandlers(node at '#{selectorComponents.join(' ')}', '#{path.join(' ')}', '#{event}', '#{wildcardEvent}', handlers #{handlers.length})"
    if path.length > 0
      if subnode = node[path[0]]
        selectorComponents.push(path[0])
        @collectHandlers(subnode, path.slice(1), event, wildcardEvent, handlers, selectorComponents)
        selectorComponents.pop()
      if subnode = node['*']
        selectorComponents.push('*')
        @collectHandlers(subnode, path.slice(1), event, wildcardEvent, handlers, selectorComponents)
        selectorComponents.pop()
    else
      if handler = node[event]
        selector = selectorComponents.concat([event]).join(' ')
        handlers.push { handler, selector }
      if wildcardEvent and (handler = node[wildcardEvent])
        selector = selectorComponents.concat([wildcardEvent]).join(' ')
        handlers.push { handler, selector }
    return handlers

  rescan: ->
    @handlerTree = {}
    @eventToSelectorToHandler = {}

    # intentionally traversing the prototype chain here
    for key, value of @controller when key.indexOf(' ') >= 0
      key = key.replace /\s+/g, ' '
      [elementSpec..., eventSpec] = splitSelector(key)

      for component in elementSpec
        unless component.match /^[#%.][a-zA-Z0-9-]+$/
          throw new Error("Invalid element spec '#{component}' in selector '#{key}' of #{@name}")
      unless eventSpec is '*' or eventSpec.match /^[a-zA-Z0-9-]+[?!]?$/
        throw new Error("Invalid event spec '#{eventSpec}' in selector '#{key}' of #{@name}")

      eventSpec = "#{eventSpec}!" unless eventSpec.match /[?!]$/

      Tree.set @handlerTree, [elementSpec..., eventSpec], value
      Tree.set @eventToSelectorToHandler, [eventSpec, elementSpec.join(' ')], value


module.exports = class UIDirector

  constructor: (rootController) ->
    @rootControllerWrapper = new UIControllerWrapper(null, [], rootController)
    @rootControllerWrapper.$ = @update.bind(@)

  start: (callback) ->
    @rootControllerWrapper.initialize()
    callback(null)

  update: (payload) ->
    C.ui.update payload

  notify: (payload) ->
    @rootControllerWrapper.notify payload
