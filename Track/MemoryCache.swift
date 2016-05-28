//The MIT License (MIT)
//
//Copyright (c) 2016 U Are My SunShine
//
//Permission is hereby granted, free of charge, to any person obtaining a copy
//of this software and associated documentation files (the "Software"), to deal
//in the Software without restriction, including without limitation the rights
//to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//copies of the Software, and to permit persons to whom the Software is
//furnished to do so, subject to the following conditions:
//
//The above copyright notice and this permission notice shall be included in all
//copies or substantial portions of the Software.
//
//THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//SOFTWARE.

/**
    MemoryCache
 
    thread safe = concurrent + semaphore lock
 
    sync
    thread safe write = write + semaphore lock
    thread safe read = read + semaphore lokc
    
    async
    thread safe write = async concurrent queue + thread safe sync write
    thread safe read = async concurrent queue + thread safe sync read
 
 */

import Foundation
import UIKit

private class MemoryCacheObject: LRUObjectBase {
    var key: String = ""
    var cost: UInt = 0
    var time: NSTimeInterval = CACurrentMediaTime()
    var value: AnyObject
    init(key: String, value: AnyObject, cost: UInt = 0) {
        self.key = key
        self.value = value
        self.cost = cost
    }
}

private func == (lhs: MemoryCacheObject, rhs: MemoryCacheObject) -> Bool {
    return lhs.key == rhs.key
}

public typealias MemoryCacheAsyncCompletion = (cache: MemoryCache?, key: String?, object: AnyObject?) -> Void

/**
 MemoryCacheGenerator, support `for`...`in` loops, it is thread safe.
 */
public class MemoryCacheGenerator : GeneratorType {
    
    public typealias Element = AnyObject
    
    private var LURGenerate: LRUGenerate<MemoryCacheObject>?
    
    private var completion: (() -> Void)?
    
    private init(generate: LRUGenerate<MemoryCacheObject>?, completion: (() -> Void)?) {
        self.LURGenerate = generate
        self.completion = completion
    }
    
    /**
    Advance to the next element and return it, or `nil` if no next element exists.
     
     - returns: next element
     */
    public func next() -> Element? {
        return self.LURGenerate?.next()?.value
    }
    
    deinit {
        completion?()
    }
}

/**
 MemoryCache is a thread safe cache implement by dispatch_semaphore_t lock and DISPATCH_QUEUE_CONCURRENT.
 Cache algorithms policy use LRU (Least Recently Used) implement by linked list and cache in NSDictionary,
 so the cache support eliminate least recently used object according count limit, cost limit and age limit,
 and support thread safe `for`...`in` loops.
 */
public class MemoryCache {
    
    /**
     Disk cache object total count
     */
    public var totalCount: UInt {
        get {
            _lock()
            let count = _cache.count
            _unlock()
            return count
        }
    }
    
    /**
     Disk cache object total cost, if not set cost when set object, total cost may be zero
     */
    public var totalCost: UInt {
        get {
            _lock()
            let cost = _cache.cost
            _unlock()
            return cost
        }
    }
    
    private var _countLimit: UInt = UInt.max
    
    /**
     The maximum total count limit
     */
    public var countLimit: UInt {
        set {
            _lock()
            _countLimit = newValue
            _unsafeTrim(toCount: newValue)
            _unlock()
        }
        get {
            _lock()
            let countLimit = _countLimit
            _unlock()
            return countLimit
        }
    }
    
    private var _costLimit: UInt = UInt.max
    
    /**
     The maximum disk cost limit
     */
    public var costLimit: UInt {
        set {
            _lock()
            _costLimit = newValue
            _unsafeTrim(toCost: newValue)
            _unlock()
        }
        get {
            _lock()
            let costLimit = _costLimit
            _unlock()
            return costLimit
        }
    }
    
    private var _ageLimit: NSTimeInterval = DBL_MAX
    
    /**
     Disk cache object age limit
     */
    public var ageLimit: NSTimeInterval {
        set {
            _lock()
            _ageLimit = newValue
            _unsafeTrim(toAge: newValue)
            _unlock()
        }
        get {
            _lock()
            let ageLimit = _ageLimit
            _unlock()
            return ageLimit
        }
    }
    
    private let _cache: LRU = LRU<MemoryCacheObject>()
    
    private let _queue: dispatch_queue_t = dispatch_queue_create(TrackCachePrefix + String(MemoryCache), DISPATCH_QUEUE_CONCURRENT)
    
    private let _semaphoreLock: dispatch_semaphore_t = dispatch_semaphore_create(1)
    
    private var _shouldRemoveAllObjectWhenMemoryWarning: Bool
    
    /**
     A share memory cache
     */
    public static let shareInstance = MemoryCache()
    
    /**
     Design constructor
     */
    public init () {
        _shouldRemoveAllObjectWhenMemoryWarning = true
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(MemoryCache._didReceiveMemoryWarningNotification), name: UIApplicationDidReceiveMemoryWarningNotification, object: nil)
    }
}

//  MARK:
//  MARK: Public
public extension MemoryCache {
    
    //  MARK: Async
    /**
     Async store an object for the unique key in memory cache and add object to linked list head
     completion will be call after object has been store in disk
     
     - parameter object:     object
     - parameter key:        unique key
     - parameter completion: stroe completion call back
     */
    public func set(object object: AnyObject, forKey key: String, cost: UInt = 0, completion: MemoryCacheAsyncCompletion?) {
        dispatch_async(_queue) { [weak self] in
            guard let strongSelf = self else { completion?(cache: nil, key: key, object: object); return }
            strongSelf.set(object: object, forKey: key, cost: cost)
            completion?(cache: strongSelf, key: key, object: object)
        }
    }
    
    /**
     Async search object according to unique key
     if find object, object will move to linked list head
     */
    public func object(forKey key: String, completion: MemoryCacheAsyncCompletion?) {
        dispatch_async(_queue) { [weak self] in
            guard let strongSelf = self else { completion?(cache: nil, key: key, object: nil); return }
            let object = strongSelf.object(forKey: key)
            completion?(cache: strongSelf, key: key, object: object)
        }
    }
    
    /**
     Async remove object according to unique key from cache dic and linked list
     */
    public func removeObject(forKey key: String, completion: MemoryCacheAsyncCompletion?) {
        dispatch_async(_queue) { [weak self] in
            guard let strongSelf = self else { completion?(cache: nil, key: key, object: nil); return }
            strongSelf.removeObject(forKey: key)
            completion?(cache: strongSelf, key: key, object: nil)
        }
    }
    
    /**
     Async remove all object and info from cache dic and clean linked list
     */
    public func removeAllObjects(completion: MemoryCacheAsyncCompletion?) {
        dispatch_async(_queue) { [weak self] in
            guard let strongSelf = self else { completion?(cache: nil, key: nil, object: nil); return }
            strongSelf.removeAllObjects()
            completion?(cache: strongSelf, key: nil, object: nil)
        }
    }
    
    /**
     Async trim disk cache total to countLimit according LRU
     
     - parameter countLimit: maximum countLimit
     */
    public func trim(toCount countLimit: UInt, completion: MemoryCacheAsyncCompletion?) {
        dispatch_async(_queue) { [weak self] in
            guard let strongSelf = self else { completion?(cache: nil, key: nil, object: nil); return }
            strongSelf.trim(toCount: countLimit)
            completion?(cache: strongSelf, key: nil, object: nil)
        }
    }
    
    /**
     Async trim disk cache totalcost to costLimit according LRU
     
     - parameter costLimit:  maximum costLimit
     */
    public func trim(toCost costLimit: UInt, completion: MemoryCacheAsyncCompletion?) {
        dispatch_async(_queue) { [weak self] in
            guard let strongSelf = self else { completion?(cache: nil, key: nil, object: nil); return }
            strongSelf.trim(toCost: costLimit)
            completion?(cache: strongSelf, key: nil, object: nil)
        }
    }
    
    /**
     Async trim disk cache objects which age greater than ageLimit
     
     - parameter costLimit:  maximum costLimit
     */
    public func trim(toAge ageLimit: NSTimeInterval, completion: MemoryCacheAsyncCompletion?) {
        dispatch_async(_queue) { [weak self] in
            guard let strongSelf = self else { completion?(cache: nil, key: nil, object: nil); return }
            strongSelf.trim(toAge: ageLimit)
            completion?(cache: strongSelf, key: nil, object: nil)
        }
    }
    
    //  MARK: Sync
    /**
     Sync store an object for the unique key in memory cache and add object to linked list head
     */
    public func set(object object: AnyObject, forKey key: String, cost: UInt = 0) {
        _lock()
        _cache.set(object: MemoryCacheObject(key: key, value: object, cost: cost), forKey: key)
        if _cache.cost > _costLimit {
            _unsafeTrim(toCost: _costLimit)
        }
        if _cache.count > _countLimit {
            _unsafeTrim(toCount: _countLimit)
        }
        _unlock()
    }
    
    /**
     Async search object according to unique key
     if find object, object will move to linked list head
     */
    @warn_unused_result
    public func object(forKey key: String) -> AnyObject? {
        var object: MemoryCacheObject? = nil
        _lock()
        object = _cache.object(forKey: key)
        object?.time = CACurrentMediaTime()
        _unlock()
        return object?.value
    }
    
    /**
     Sync remove object according to unique key from cache dic and linked list
     */
    public func removeObject(forKey key: String) {
        _lock()
        _cache.removeObject(forKey:key)
        _unlock()
    }
    
    /**
     Sync remove all object and info from cache dic and clean linked list
     */
    public func removeAllObjects() {
        _lock()
        _cache.removeAllObjects()
        _unlock()
    }
    
    /**
     Sync trim disk cache totalcost to costLimit according LRU
     */
    public func trim(toCount countLimit: UInt) {
        _lock()
        _unsafeTrim(toCount: countLimit)
        _unlock()
    }
    
    /**
     Sync trim disk cache totalcost to costLimit according LRU
     */
    public func trim(toCost costLimit: UInt) {
        _lock()
        _unsafeTrim(toCost: costLimit)
        _unlock()
    }
    
    /**
     Sync trim disk cache objects which age greater than ageLimit
     
     - parameter costLimit:  maximum costLimit
     */
    public func trim(toAge ageLimit: NSTimeInterval) {
        _lock()
        _unsafeTrim(toAge: ageLimit)
        _unlock()
    }
    
    /**
     subscript method, sync set and get
     
     - parameter key: object unique key
     */
    public subscript(key: String) -> AnyObject? {
        get {
            return object(forKey: key)
        }
        set {
            if let newValue = newValue {
                set(object: newValue, forKey: key)
            } else {
                removeObject(forKey: key)
            }
        }
    }
}

//  MARK: SequenceType
extension MemoryCache : SequenceType {
    /**
     MemoryCacheGenerator
     */
    public typealias Generator = MemoryCacheGenerator
    
    /**
     Returns a generator over the elements of this sequence.
     It is thread safe, if you call `generate()`, remember release it,
     otherwise maybe it lead to deadlock.
     
     - returns: A generator
     */
    @warn_unused_result
    public func generate() -> MemoryCacheGenerator {
        var generatror: MemoryCacheGenerator
        _lock()
        generatror = MemoryCacheGenerator(generate: _cache.generate()) {
            self._unlock()
        }
        return generatror
    }
}

//  MARK:
//  MARK: Private
private extension MemoryCache {
    
    @objc private func _didReceiveMemoryWarningNotification() {
        if _shouldRemoveAllObjectWhenMemoryWarning {
            removeAllObjects(nil)
        }
    }
    
    private func _unsafeTrim(toCount countLimit: UInt) {
        if _cache.count <= countLimit {
            return
        }
        if countLimit == 0 {
            _cache.removeAllObjects()
            return
        }
        if var _: MemoryCacheObject = _cache.lastObject() {
            while (_cache.count > countLimit) {
                _cache.removeLastObject()
                guard let _: MemoryCacheObject = _cache.lastObject() else { return }
            }
        }
    }
    
    private func _unsafeTrim(toCost costLimit: UInt) {
        if _cache.cost <= costLimit {
            return
        }
        if costLimit == 0 {
            _cache.removeAllObjects()
            return
        }
        if var _: MemoryCacheObject = _cache.lastObject() {
            while (_cache.cost > costLimit) {
                _cache.removeLastObject()
                guard let _: MemoryCacheObject = _cache.lastObject() else { return }
            }
        }
    }
    
    private func _unsafeTrim(toAge ageLimit: NSTimeInterval) {
        if ageLimit <= 0 {
            _cache.removeAllObjects()
            return
        }
        if var lastObject: MemoryCacheObject = _cache.lastObject() {
            while (CACurrentMediaTime() - lastObject.time > ageLimit) {
                _cache.removeLastObject()
                guard let newLastObject: MemoryCacheObject = _cache.lastObject() else { return }
                lastObject = newLastObject
            }
        }
    }
    
    func _lock() {
        dispatch_semaphore_wait(_semaphoreLock, DISPATCH_TIME_FOREVER)
    }
    
    func _unlock() {
        dispatch_semaphore_signal(_semaphoreLock)
    }
}
