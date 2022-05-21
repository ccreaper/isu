
-- isu: a minimal, lightweight library for building reactive user interfaces in the Roblox engine.
-- https://github.com/ccreaper/isu

-- Generic
local assert = assert
local getType = typeof or type
local coroRunning = coroutine.running
local unpack = table.unpack or unpack
local next = next
local getmt = getmetatable
local setmt = setmetatable

-- Roblox specific
local instanceNew = Instance and Instance.new
local tweenService = game and game:GetService("TweenService")
local connect = game.Destroying.Connect
local disconnect = connect(game.Destroying,function()end).Disconnect

local isu = {}

---@class WeakTable
---@field v any

local WEAK_MT_K = {__mode = 'k'}
local WEAK_MT_V = {__mode = 'v'}
local WEAK_MT_KV = {__mode = 'kv'}
local _contextStorage = setmt({}, WEAK_MT_K)
-- Creates a weak reference holder (weak table) and returns it.
-- Data is pointed to by `self.v`, but can be stored anywhere in the table.
---@param value any
---@return WeakTable
local function weakRef(value)
    return setmt({v = value}, WEAK_MT_V)
end

-- Clones a table. If `deep` is truthy, all nested tables will be cloned too.
---@param t table
---@param deep? boolean
---@return table
local function clone(t, deep)
    local nt = {}
    for key, delta in next, t do
        local nK, nD = key, delta
        if getType(key) == 'table' and deep then
            nK = clone(key, deep)
        end
        if getType(delta) == 'table' and deep then
            nD = clone(delta, deep)
        end
        nt[nK] = nD
    end
    return nt
end

---@class Accumulator
---@field stk table
---@return Accumulator
local function accumulator()
    return {
        stk = {},
        coro = setmt({}, WEAK_MT_KV),
        rst = function(a)
            a.coro[coroRunning()] = 0
        end,
        inc = function(a)
            local running = coroRunning()
            a.coro[running] = a.coro[running] + 1
            return a:at(a.coro[running]), a.coro[running]
        end,
        frz = function(a)
            if a.fi then
                if a.fi ~= #a.stk then
                    return error('Variadic accumulation has been detected during composition. Make sure that you are not conditionally invoking hooks (for instance, within an if statement).', 2)
                end
            end
            a.fi = #a.stk
        end,
        at = function(a, i)
            return a.stk[i]
        end,
        set = function(a, i, v)
            a.stk[i] = v
        end,
        add = function(a, v)
            a.stk[#a.stk+1] = v
            return v
        end,
    }
end

local CONTEXT_ACCUMULATORS = {
    'obj', 'st', 'efc', 'unm', 'evt',
    'trs', 'anm', 'sbc', 'sub'
}
---@class Context
---@field prev WeakTable|nil Weak reference to the currently rendered object.
---@field props table Properties of the component. Can be mutated on renders.
---@field obj Accumulator Stores and caches created instances.
---@field st Accumulator Variables declared in the renderer.
---@field efc Accumulator Holds mounting callbacks.
---@field unm Accumulator Holds unmounting callbacks.
---@field evt Accumulator Event callbacks to be connected to rendered objects.
---@field trs Accumulator Tween generator for mutated properties.
---@field anm Accumulator Tween generator for user-mutated properties.
---@field ani table Dictionary mapping property names to a boolean representing whether they were user-animated for this render.
---@field sbc Accumulator Nested components created at render time.
---@field sub Accumulator Subscription-based stateful variables.

-- Sets the coroutine's current context to def.
---@param def any Default value to set context to.
---@return Context
local function cset(def)
    local coro = coroRunning()
    _contextStorage[coro] = def
    return _contextStorage[coro]
end

-- Retrieves the context from the coroutine. Can be nil.
---@return Context|nil
local function cget()
    return _contextStorage[coroRunning()]
end

-- Calls `fn` with the supplied context `ctx`. Varargs are passed to `fn`.
---@param ctx Context
---@param fn function
---@vararg any
local function cuse(ctx, fn, preserverts)
    local previous = cget()
    cset(ctx)
    local result = {fn()}
    cset(previous)
    return preserverts and unpack(result)
end

-- Verifies if a hook is enabled in this component.
local function assertUsability(hookName)
    local c = cget()
    return (
        c.opts[hookName] or
        c.opts['enableAll']
    ) or error('"' .. hookName .. '" is not enabled in this component builder.')
end

local makeInstance
do --> context-aware instance creation
    local function make(className, properties)
        local inst = getType(className) == 'Instance' and className or instanceNew(className)
        for key, delta in next, properties do
            if getType(key) == 'number' then
                delta().Parent = inst
            else
                local t = getType(delta) == 'table' and getmt(delta)
                if t and t.tt == 'Subscription' then
                    inst[key] = delta.value
                else
                    inst[key] = delta
                end
            end
        end
        return inst
    end

    -- Contextually constructs an instance with the provided properties.
    -- If the current context has a listing for this instance, it will be returned instead of instancing a new object.
    ---@param className string
    ---@param properties table
    ---@return Instance
    function makeInstance(className, properties)
        assert(instanceNew, 'Instance creation is not supported.')
        local ctx = cget()
        local current = ctx.obj:inc()
        if not current then
            properties = properties or {}
            current = make(className, properties)
            ctx.obj:add(current)
            connect(current.Destroying, function()
                for _, unmounter in next, ctx.unm.stk do
                    unmounter()
                end
            end)
        end
        for _, event in next, ctx.evt.stk do
            event.connection = connect(current[event.name], event.fn)
        end
        return current
    end
end

---@class Transition
---@field fn function
---@field name string

-- Performs a transition contextually.
---@param instance Instance
---@param property string
---@param toValue any
---@param transition Transition
---@return boolean
local function performTransition(instance, property, toValue, transition)
    assert(tweenService, 'Tweening is not supported.')

    local onEnd
    local function useTransitionComplete(endFn)
        onEnd = endFn
    end

    local tween = tweenService:Create(instance,
        TweenInfo.new(transition.fn(toValue, useTransitionComplete)), {
        [property] = toValue
    })

    if onEnd then
        connect(tween.Completed, onEnd)
    end
    tween:Play()
    return true
end

-- Mutates an instance conditionally, only overwriting fields when they have changed,
---@param src Instance
---@param new table
---@return Instance
local function mutateConditionally(src, new)
    for key, delta in next, new do
        if getType(key) ~= 'number' then
            local ctx = cget()
            local t1, t2 = getType(src[key]), getType(delta)
            if t2 == 'table' then
                -- check if special object
                local mt = getmt(delta)
                if mt and mt.tt then
                    if mt.tt == 'Subscription' then
                        delta.represents.listeners[key] = function(newValue)
                            src[key] = newValue
                        end
                        src[key] = delta.value
                    end
                else
                    src[key] = delta
                end
            elseif t1 ~= t2 then
                -- mutate due to differing types
                src[key] = delta
            elseif ctx.ani[key] then
                for _, v in next, ctx.anm.stk do
                    if v.name == key then
                        performTransition(src, key, ctx.ani[key], v)
                    end
                end
            elseif src[key] ~= delta then
                -- mutate on differing values
                local hast = {}
                for _, v in next, ctx.trs.stk do
                    if v.name == key then
                        hast[key] = performTransition(src, key, delta, v)
                    end
                end
                if not hast[key] then
                    src[key] = delta
                end
            end
        else
            delta() -- run rerenderer
        end
    end
    return src
end

-----------------------------------------------

-- Creates a stateful variable, which is a reactive value that can be dynamically updated.
-- The variable is bound to the component in which it has been declared, and any changes made
-- to the variable through its updater function will automatically re-render the component.
-- For more information: https://reactjs.org/docs/hooks-reference.html#usestate
---@generic T : any
---@param value T
---@return T Value @The current value. Will update automatically after the updater has been called.
---@return fun(newValue:T) Updater @The stateful updater. Call this to update the state with a new value.
function isu.useState(value)
    local ctx = cget()
    local current, i = ctx.st:inc()
    if current then
        return current.value, current.updater
    else
        local state
        state = ctx.st:add({
            value = value,
            updater = function(newValue)
                if ctx.st:at(i).value ~= newValue then
                    state.value = newValue
                    ctx.render()
                end
            end
        })
        return state.value, state.updater
    end
end

-- Applies lifecycle hooks to the current component based on `fn`'s behavior.
-- If no states are supplied, then the callback will be invoked when the component is first rendered,
-- and its return value, which can be a function, will be invoked when the component is unmounted.
-- If no function is returned, then nothing will be invoked at unmount. If some states are supplied,
-- then the effect hook will only execute when these specific states are updated.
-- For more information: https://reactjs.org/docs/hooks-reference.html#useeffect
---@param fn function
---@param states? any[]
function isu.useEffect(fn, states)
    local ctx = cget()
    local current = ctx.efc:inc()
    if not current then
        ctx.efc:add({fn=fn,states=states or {}})
    elseif states then
        for i = 1, #states do
            if current.st[i] ~= states[i] then
                current.fn()
                break
            end
        end
    end
end

-- Connects `callback` to the constructed object's event named `eventName`.
-- The event must be directly indexable using the supplied name (for instance,
-- property change events requiring `GetPropertyChangedSignal` cannot be accessed
-- using useEvent and requires special syntax).
-- The callback signal will be dynamically disconnected and reconnected at multiple
-- points during the lifecycle of the component, and the state of the component can
-- be updated at will during an event's invocation.
--
-- **Example used on a TextLabel:**
-- ```
-- useEvent('MouseButton1Click', function()
--     print('The instance has been clicked!')
-- end)
-- ```
---@param eventName string
---@param connection function
function isu.useEvent(eventName, connection)
    assertUsability('useEvent')
    local ctx = cget()
    local current = ctx.evt:inc()
    if current then
        disconnect(current.connection)
        current.connection = nil
        current.fn = connection
    else
        ctx.evt:add({ name = eventName, fn = connection })
    end
end

-- Subjects an instance property to a transition (such as a tween) when it is
-- mutated by the reconciliation/diffing process. `tweenCalculator` must be a
-- function that returns the parameters to construct a new tween, and it can
-- accept two arguments: the new value that will be transitioned to, and a
-- callback that accepts a function which will be invoked when the transition ends.
--
-- **Example:**
-- ```
-- useTransition('Position', function(newValue, onTransitionEnd)
--     onTransitionEnd(function()
--         print('Transition has ended.')
--     end)
--     return 0.3, Enum.EasingStyle.Quad
-- end)
-- ```
---@param propertyName string
---@param tweenCalculator fun(newValue:any,onTransitionEnd:fun(callback:function))
function isu.useTransition(propertyName, tweenCalculator)
    assertUsability('useTransition')
    local ctx = cget()
    local current = ctx.trs:inc()
    if not current then
        ctx.trs:add({name=propertyName, fn=tweenCalculator})
    end
end

-- Returns a function that animates a property upon invocation. `useAnimation`
-- accepts the same arguments as `useTransition` and their behavior is the same,
-- but while `useTransition` applies an animation _when_ a property is mutated,
-- `useAnimation` only applies an animation when the user requests it through
-- the returned callback, passing the new value to animate to as an argument.
--
-- **Take note that the callback does not immediately trigger the animation.**
-- Instead, it schedules it to be performed on the next re-render, similarly to
-- `useTransition`'s mechanism. In most cases, the animation should be performed
-- straight away as hook usage often triggers a re-render, but in the case that
-- it doesn't, you can manually force a re-render through `useTriggerableRender`
-- after scheduling your animation(s).
--
-- **Example:**
-- ```
-- local rerender = useTriggerableRender()
-- local anim = useAnimation('Position', function(newValue, onTransitionEnd)
--     onTransitionEnd(function()
--         print('Transition has ended.')
--     end)
--     return 0.3, Enum.EasingStyle.Quad
-- end)
-- useEvent('MouseButton1Click', function()
--     anim(UDim2.new(0, 100 * math.random(), 0, 100 * math.random()))
--     rerender()
-- end)
-- ```
---@generic T
---@param propertyName string
---@param tweenCalculator fun(newValue:any,onTransitionEnd:fun(callback:function))
---@return fun(newValue:T)
function isu.useAnimation(propertyName, tweenCalculator)
    assertUsability('useAnimation')
    local ctx = cget()
    return (ctx.anm:inc() or ctx.anm:add({
        name = propertyName, fn = tweenCalculator,
        perform = function(newValue)
            ctx.ani[propertyName] = newValue
        end
    })).perform
end

local SUBSCRIPTION_MT = {
    tt = 'Subscription',
    __call = function(t, optional)
        return optional and t.represents.updater(optional) or t.value
    end
}
-- Creates a subscription-based stateful value. This hook serves as a more performant
-- alternative to `useState` when the value only needs to be accessed and updated within another
-- hook (such as `useEvent` or `useEffect`) and not within the renderer function directly.
-- When a subscription's value updates, the value is directly applied to the Instance instead
-- of passing through the library's reconciliation and diffing process, which invokes the renderer.
-- The usual use of a subscription is when a value is used exclusively within an Instance's properties.
--
-- **Subscriptions should not be used if your code repeatedly needs to read its value.** Occasional
-- access through hooks is fine, but `useState` is the superior option to use if your renderer
-- needs to access the value regularly, since the subscription's method of reading is less performant.
-- 
-- `useSubscription` returns a single function which, when called with no arguments, returns the
-- current value. However, when it is called with a single argument, the value of the subscription
-- is updated to the value passed through the argument and the Instance is updated accordingly. Only
-- this function is necessary, but for compatibility with the `useState` syntax, a second function will
-- also be returned that exclusively updates the value of the subscription.
--
-- **Example:**
-- ```
-- local time = useSubscription(workspace.DistributedGameTime)
-- print("This should only be printed once, unlike the useState hook!")
-- useEffect(function()
--		task.spawn(function()
--			while task.wait() do
--				time(workspace.DistributedGameTime)
--			end
--		end)
--	end)
-- return 'TextButton', { Size = UDim2.new(0, 200, 0, 200), Text = time }
-- ```
---@generic T
---@param value any
---@return fun(newValue?:T) @Updater-retriever. Calling it without an argument retrieves the value, and calling it with an argument updates the value.
function isu.useSubscription(value)
    assertUsability('useSubscription')
    local ctx = cget()
    local current, i = ctx.sub:inc()
    if current then
        return current.proxy, current.updater
    else
        local sub = {listeners = {}, value = value}
        sub.proxy = setmt({
            value = value,
            represents = sub
        }, SUBSCRIPTION_MT)
        sub.updater = function(newValue)
            if ctx.sub:at(i).value ~= newValue then
                sub.value = newValue
                sub.proxy.value = newValue
                for _, listener in next, sub.listeners do
                    listener(newValue)
                end
            end
            return newValue
        end
        ctx.sub:add(sub)
        return sub.proxy, current.updater
    end
end

-- Returns a callback that re-renders the component when invoked.
-- Avoids React's [forced re-render problem](https://stackoverflow.com/questions/46240647/react-how-to-force-a-function-component-to-render/53837442)
-- in functional components.
---@return function
function isu.useTriggerableRender()
    return cget().render
end

-- Creates a component builder, which can be called to create new components
-- with a renderer and hooks. The library uses the builder to construct the
-- Instance component factory at `isu.component`.
---@param instantiator function @This function must accept a class name and a dictionary of properties at minimum. The table can also include an array part composed of subcomponents, but this behavior may be safely ignored if not relevant.
---@param mutator function @This function is used to mutate an existing object. It must accept the instance to mutate and a dictionary of properties to assign. A common optimization is to only assign a property if its value has changed.
---@param opts? table @You can enable special hooks (such as `useEvent` and `useAnimation`) by setting them to true in this table (`["useEvent"] = true`). Essential hooks such as `useState` and `useEffect` are always available.
---@return function
function isu.builder(instantiator, mutator, opts)
    opts = opts or {}
    -- returns a factory which can be made
    -- to build a component from props
    return function(renderer, hydrateThis)
        return function(props)
            if not opts.hydration and hydrateThis then
                return error('Hydration not enabled in builder options.')
            end

            local context = {
                opts = opts,
                prev = weakRef(),
                props = props,
                ani = {}
            }

            if cget() then
                -- constructed within other component
                local cctx = cget()
                local current = cctx.sbc:inc()
                if current then
                    current.props = props
                    return current.render
                else
                    cctx.sbc:add(context)
                end
            end

            for i = 1, #CONTEXT_ACCUMULATORS do
                context[CONTEXT_ACCUMULATORS[i]] = accumulator()
            end

            context.render = coroutine.wrap(function()
                while true do
                    coroutine.yield(cuse(context, function()
                        for i = 1, #CONTEXT_ACCUMULATORS do
                            context[CONTEXT_ACCUMULATORS[i]]:rst()
                        end

                        local className, nprops = renderer(context.props)
                        if getType(className) ~= 'string' or getType(nprops) ~= 'table' then
                            error('Component renderer must return a classname and properties.')
                        end

                        -- Can detect varadic (conditional) hook use.
                        -- Error if the current hook counts aren't similar
                        -- to the previous hook counts.
                        -- An exception is made for the objects accumulator,
                        -- whose value is mediated by the mutator and not
                        -- by the renderer.
                        for i = 1, #CONTEXT_ACCUMULATORS do
                            local s = CONTEXT_ACCUMULATORS[i]
                            if s ~= 'obj' then
                                context[s]:frz()
                            end
                        end

                        local inst = instantiator(hydrateThis or className, nprops)
                        mutator(inst, nprops)
                        if not context.prev.v or (not context.prev.v and hydrateThis) then
                            context.prev.v = inst
                            for _, effect in next, context.efc.stk do
                                local unmounter = effect.fn()
                                if unmounter and not context.unm:inc() then
                                    context.unm:add(unmounter)
                                end
                            end
                        end

                        if opts.useAnimation then
                            context.ani = {}
                        end
                        return inst
                    end, true))
                end
            end)

            return context.render
        end
    end
end

local INSTANCE_BUILDER = isu.builder(makeInstance, mutateConditionally, {
    enableAll = true -- enable all hooks on instances
})
-- Creates a new component and returns its factory, a function used to construct
-- component instances. Calling the factory instanciates a component with an initial
-- dictionary of user-defined props passed as a parameter, and returns a function that can
-- be used to (re)render the component, finally returning the instance itself.
--
-- The renderer **must** return a string indicating the class name of the instance
-- to create, and a dictionary of instance properties which can accept reactive values.
-- This dictionary will be used to differentiate, reconcile and update the instance.
-- The dictionary can also have an array part (values without keys) in which you can
-- list child components that will be parented to the instance at mount.
--
-- **Example:**
-- ```
-- component(function(props)
--     return 'TextLabel', {
--         Text = 'Hello world!'
--     }
-- end)
-- ```
---@generic Props any
---@param renderer fun(props:Props):string,table
---@return fun(props:Props):fun():Instance
function isu.component(renderer)
    return INSTANCE_BUILDER(renderer)
end

local INSTANCE_HYDRATE = isu.builder(makeInstance, mutateConditionally, {
    hydration = true, -- enable hydration for this builder
    enableAll = true -- enable all hooks on instances
})
-- Hydrates (updates) an already existing object with the renderer instead of
-- creating one. Initial properties can also be provided. Otherwise, behavior
-- is the exact same as the component factory, but returns nothing.
--
-- **Hydration does not automatically hydrate any subcomponents.**
-- You will have to hydrate any children manually and remove their factory
-- in the renderer's returned properties, or leave their creation up to the
-- renderer.
---@param object Instance
---@param renderer function
---@param props? table
function isu.hydrate(object, renderer, props)
    INSTANCE_HYDRATE(renderer, object)(props)()
end

return isu