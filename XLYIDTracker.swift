//
//  XLYIDTracker
//
//  Created by 王凯 on 14-9-24.
//  Copyright (c) 2014年 kaizei. All rights reserved.
//

import Foundation

/*
    //create a tracker with a given queue and store it somewhere
    var tracker: XLYIDTracker = XLYIDTracker(trackerQueue: dispatch_queue_create("tracker", DISPATCH_QUEUE_SERIAL))

    // make a common handler for response
    var handler: XLYTrackingHandler = { (trackingInfo, response) -> () in
        if let value = response {
            println("get response : \(value)")
        } else {
            println("no response get")
        }
    }
    // must add trackingInfos in tracker's queue
    dispatch_async(tracker.trackerQueue) {
        //default queue uses tracker's queue
        tracker.addTrackingInfo("a", timeOut: 2, queue: nil, handler)
        //track in the main queue
        tracker.addTrackingInfo("b", timeOut: 2, queue: dispatch_get_main_queue(), handler)

        var queue = dispatch_queue_create("queue", DISPATCH_QUEUE_SERIAL)
        //track in a custom queue
        tracker.addTrackingInfo("c", timeOut: 2, queue: queue, handler)
        //or you can create a trackingInfo and then add it
        var trackingInfo = XLYBasicTrackingInfo(trackID: "d", timeOut: 2, queue: queue, handler)
        tracker.addTrackingInfo(trackingInfo)
    }
*/

/// trackingInfo 的回调方法，传递trackinginfo和回应的数据，如果没有数据则为nil
public typealias XLYTrackingHandler = (trackingInfo: XLYTrackingInfo, response:Any?) -> ()

//MARK: XLYIDTracker
public class XLYIDTracker {
    public let trackerQueue: dispatch_queue_t
    private var trackingInfos = [String : XLYTrackingInfo]()
    private let queueTag = UnsafeMutablePointer<Void>(malloc(1))
    
    public init(trackerQueue:dispatch_queue_t) {
        self.trackerQueue = trackerQueue
        dispatch_queue_set_specific(trackerQueue, queueTag, queueTag, nil)
    }
    
    private let lock = NSLock()
    private subscript(trackID: String) -> XLYTrackingInfo? {
        get {
            assert(queueTag == dispatch_get_specific(queueTag), "must invoke tracker methods in tracker queue")
            lock.lock()
            let trackingInfo = trackingInfos[trackID]
            lock.unlock()
            return trackingInfo
        }
        set {
            assert(queueTag == dispatch_get_specific(queueTag), "must invoke tracker methods in tracker queue")
            assert(newValue?.tracker == nil, "can not add a trackingInfo which already has a tracker associated")
            lock.lock()
            if let trackingInfo = trackingInfos.removeValueForKey(trackID) {
                trackingInfo.cancelTimer()
            }
            if var trackingInfo = newValue {
                trackingInfos[trackID] = trackingInfo
                trackingInfo.tracker = self
                trackingInfo.startTimer()
            }
            lock.unlock()
        }
    }
    
    ///通过trackID和回调方法来创建trackingInfo，会使用默认的trackingInfo实现
    public func addTrackingInfo(trackID: String, timeOut: NSTimeInterval, queue: dispatch_queue_t?, handler: XLYTrackingHandler) {
        let trackingInfo = XLYBasicTrackingInfo(trackID: trackID, timeOut: timeOut, queue: queue ?? self.trackerQueue, handler: handler)
        addTrackingInfo(trackingInfo)
    }
    
    ///添加一个配置好的trackingInfo，会覆盖已有的trackingInfo
    public func addTrackingInfo(var trackingInfo: XLYTrackingInfo) {
        self[trackingInfo.trackID] = trackingInfo
    }
    
    ///响应一个tracking, 如果响应成功返回true，否则返回NO
    public func responseTrackingForID(trackID: String, response: Any?) -> Bool {
        if let trackingInfo = self[trackID] {
            self[trackID] = nil
            dispatch_async(trackingInfo.trackQueue, {trackingInfo.response(response)})
            return true
        }
        return false
    }
    
    ///停止track
    public func stopTrackingForID(trackID: String) {
        self[trackID] = nil
    }
    
    ///停止所有的tracking
    public func stopAllTracking() {
        for trackID in trackingInfos.keys {
            self[trackID] = nil
        }
    }
}

//MARK: - XLYTrackingInfo protocol
/// all properties and functions should not be called directly.
public protocol XLYTrackingInfo {
    ///标识唯一的track id.
    var trackID: String {get}
    ///track所使用的queue，计时应该在这个queue里面进行
    var trackQueue: dispatch_queue_t {get}
    ///所从属的tracker
    weak var tracker: XLYIDTracker! {get set}
    
    init(trackID: String, timeOut: NSTimeInterval, queue :dispatch_queue_t, handler: XLYTrackingHandler)
    ///开始计时，应该在trackQueue里面进行，超时后需要调用tracker的response方法并传递自定义的错误信息比如nil
    func startTimer()
    ///停止计时，取消掉timer
    func cancelTimer()
    ///响应一个track，可以是任何对象，由tracker在trackQueue中进行调用
    func response(response: Any?)
}

//MARK: - XLYBasicTrackingInfo
public class XLYBasicTrackingInfo: XLYTrackingInfo {
    public let trackID: String
    public let trackQueue: dispatch_queue_t
    public weak var tracker: XLYIDTracker!
    private let trackTimeOut: NSTimeInterval = 15
    private let trackHandler: XLYTrackingHandler
    private var trackTimer: dispatch_source_t?
    private let queueTag = UnsafeMutablePointer<Void>(malloc(1))
    
    required public init(trackID: String, timeOut: NSTimeInterval, queue :dispatch_queue_t, handler: XLYTrackingHandler) {
        self.trackID = trackID
        trackHandler = handler
        trackQueue = queue
        if timeOut > 0 {
            trackTimeOut = timeOut
        }
        dispatch_queue_set_specific(queue, queueTag, queueTag, nil)
    }
    
    deinit {
        cancelTimer()
    }
    
    ///超时后response为nil，意味着没有规定时间内没有得到响应数据
    public func startTimer() {
        assert(trackTimer == nil, "XLYBasicTrackingInfo class can start counting down only when timer is stoped.")
        assert(tracker != nil, "XLYBasicTrackingInfo class must have tracker set to perform response")
        trackTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, trackQueue);
        dispatch_source_set_event_handler(trackTimer) {
            [weak self] in
            autoreleasepool(){
                if let tracker = self?.tracker {
                    if let trackID = self?.trackID {
                        dispatch_async(tracker.trackerQueue) {
                            ///swift的问题，如果只有一个语句则一定返回该语句的执行结果
                            ///现在这个返回值和要求的Void不符合，所以。。。
                            doNoting()
                            tracker.responseTrackingForID(trackID, response: nil)
                        }
                    }
                }
            }
        }
        let tt = dispatch_time(DISPATCH_TIME_NOW, Int64(trackTimeOut * NSTimeInterval(NSEC_PER_SEC)));
        dispatch_source_set_timer(trackTimer!, tt, DISPATCH_TIME_FOREVER, 0)
        dispatch_resume(trackTimer!);
    }
    
    public func cancelTimer() {
        if let timer = trackTimer {
            dispatch_source_cancel(timer)
            trackTimer = nil
        }
    }
    
    public func response(response: Any?) {
        assert(queueTag == dispatch_get_specific(queueTag), "should response in XLYBasicTrackingInfo.trackQueue.")
        autoreleasepool() {
            self.trackHandler(trackingInfo: self, response: response)
        }
    }
}

//MARK: - a function do noting...
private func doNoting(){}
