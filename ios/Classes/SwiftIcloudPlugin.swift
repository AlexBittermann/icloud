import Flutter
import UIKit

public class SwiftIcloudPlugin: NSObject, FlutterPlugin {
    var availabilityStreamHandler: StreamHandler?
    var listStreamHandler: StreamHandler?
    var messenger: FlutterBinaryMessenger?
    var containerId: String?
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let messenger = registrar.messenger();
        let channel = FlutterMethodChannel(name: "icloud", binaryMessenger: messenger)
        let instance = SwiftIcloudPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        instance.messenger = messenger
        
        let availabilityEventChannel = FlutterEventChannel(name: "icloud/event/availability", binaryMessenger: registrar.messenger())
        instance.availabilityStreamHandler = StreamHandler()
        availabilityEventChannel.setStreamHandler(instance.availabilityStreamHandler)
        
        let listEventChannel = FlutterEventChannel(name: "icloud/event/list", binaryMessenger: registrar.messenger())
        instance.listStreamHandler = StreamHandler()
        listEventChannel.setStreamHandler(instance.listStreamHandler)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isAvailable":
            isAvailable(call, result)
        case "watchAvailability":
            watchAvailability(call, result)
        case "initialize":
            initialize(call, result)
        case "listFiles":
            listFiles(call, result)
        case "upload":
            upload(call, result)
        case "download":
            download(call, result)
        case "delete":
            delete(call, result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func isAvailable(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        result(FileManager.default.ubiquityIdentityToken != nil)
    }
    
    private func watchAvailability(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        result(nil)
        availabilityStreamHandler?.onCancelHandler = { [self] in
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name.NSUbiquityIdentityDidChange, object: nil)
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name.NSUbiquityIdentityDidChange, object: nil, queue: .main) {
            [self] (notification) in
            availabilityStreamHandler?.setEvent(FileManager.default.ubiquityIdentityToken != nil)
        }
    }
    
    private func initialize(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? Dictionary<String, Any>
        else {
            result(argumentError)
            return
        }
        self.containerId = args["containerId"] as? String
        result(nil)
    }
    
    private func listFiles(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? Dictionary<String, Any>,
              let watchUpdate = args["watchUpdate"] as? Bool
        else {
            result(argumentError)
            return
        }
        
        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: containerId)
        else {
            result(containerError)
            return
        }
        DebugHelper.log("containerURL: \(containerURL.path)")
        
        let query = NSMetadataQuery.init()
        query.operationQueue = .main
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        query.predicate = NSPredicate(format: "%K beginswith %@", NSMetadataItemPathKey, containerURL.path)
        addListFilesObservers(query: query, containerURL: containerURL, watchUpdate: watchUpdate, result: result)
        
        if watchUpdate { result(nil) }
        query.start()
    }
    
    private func addListFilesObservers(query: NSMetadataQuery, containerURL: URL, watchUpdate: Bool, result: @escaping FlutterResult) {
        NotificationCenter.default.addObserver(forName: NSNotification.Name.NSMetadataQueryDidFinishGathering, object: query, queue: query.operationQueue) {
            [self] (notification) in
            onListQueryNotification(query: query, containerURL: containerURL, watchUpdate: watchUpdate, result: result)
        }
        
        if watchUpdate {
            listStreamHandler?.onCancelHandler = { [self] in
                removeObservers(query)
                query.stop()
            }
            NotificationCenter.default.addObserver(forName: NSNotification.Name.NSMetadataQueryDidUpdate, object: query, queue: query.operationQueue) {
                [self] (notification) in
                onListQueryNotification(query: query, containerURL: containerURL, watchUpdate: watchUpdate, result: result)
            }
        }
    }
    
    private func onListQueryNotification(query: NSMetadataQuery, containerURL: URL, watchUpdate: Bool, result: @escaping FlutterResult) {
        var filePaths: [[String : Any?]] = []
        for item in query.results {
            guard let fileItem = item as? NSMetadataItem else { continue }
            guard let fileURL = fileItem.url else { continue }
            if fileURL.absoluteString.last == "/" { continue }
            let relativePath = String(fileURL.absoluteString.dropFirst(containerURL.absoluteString.count))
            filePaths.append([
                "url": relativePath,
                "size": fileItem.fileSize,
                "modifiedDate": fileItem.modifiedDate?.iso8601WithFractrionalSeconds
            ])
        }
        if watchUpdate, let streamHandler = listStreamHandler {
            streamHandler.setEvent(filePaths)
        } else {
            removeObservers(query, watchUpdate: false)
            query.stop()
            result(filePaths)
        }
    }
    
    private func upload(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? Dictionary<String, Any>,
              let localFilePath = args["localFilePath"] as? String,
              let cloudFileName = args["cloudFileName"] as? String,
              let watchUpdate = args["watchUpdate"] as? Bool
        else {
            result(argumentError)
            return
        }
        
        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: containerId)
        else {
            result(containerError)
            return
        }
        DebugHelper.log("containerURL: \(containerURL.path)")
        
        let cloudFileURL = containerURL.appendingPathComponent(cloudFileName)
        let localFileURL = URL(fileURLWithPath: localFilePath)
        
        do {
            if !FileManager.default.fileExists(atPath: containerURL.path) {
                try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true, attributes: nil)
            }
            let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(localFileURL.lastPathComponent, isDirectory: false)
            try FileManager.default.copyItem(at: localFileURL, to: tempFile)
            _ = try FileManager.default.replaceItemAt(cloudFileURL, withItemAt: tempFile)
            if !watchUpdate { result(nil) }
        } catch {
            result(nativeCodeError(error))
        }
        
        if watchUpdate, let messenger = self.messenger {
            let query = NSMetadataQuery.init()
            query.operationQueue = .main
            query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
            query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemPathKey, cloudFileURL.path)
            
            let uploadEventChannel = FlutterEventChannel(name: "icloud/event/upload/\(cloudFileName)", binaryMessenger: messenger)
            let uploadStreamHandler = StreamHandler()
            uploadStreamHandler.onCancelHandler = { [self] in
                removeObservers(query)
                query.stop()
            }
            uploadEventChannel.setStreamHandler(uploadStreamHandler)
            addUploadObservers(query: query, streamHandler: uploadStreamHandler)
            
            result(nil)
            query.start()
        }
    }
    
    private func addUploadObservers(query: NSMetadataQuery, streamHandler: StreamHandler) {
        NotificationCenter.default.addObserver(forName: NSNotification.Name.NSMetadataQueryDidFinishGathering, object: query, queue: query.operationQueue) { [self] (notification) in
            onUploadQueryNotification(query: query, streamHandler: streamHandler)
        }
        
        NotificationCenter.default.addObserver(forName: NSNotification.Name.NSMetadataQueryDidUpdate, object: query, queue: query.operationQueue) { [self] (notification) in
            onUploadQueryNotification(query: query, streamHandler: streamHandler)
        }
    }
    
    private func onUploadQueryNotification(query: NSMetadataQuery, streamHandler: StreamHandler) {
        if query.results.count == 0 {
            return
        }
        
        guard let fileItem = query.results.first as? NSMetadataItem else { return }
        guard let fileURL = fileItem.value(forAttribute: NSMetadataItemURLKey) as? URL else { return }
        guard let fileURLValues = try? fileURL.resourceValues(forKeys: [.ubiquitousItemIsUploadingKey]) else { return}
        guard let isUploading = fileURLValues.ubiquitousItemIsUploading else { return }
        
        if let error = fileURLValues.ubiquitousItemUploadingError {
            streamHandler.setEvent(nativeCodeError(error))
            return
        }
        
        if let progress = fileItem.value(forAttribute: NSMetadataUbiquitousItemPercentUploadedKey) as? Double {
            streamHandler.setEvent(progress)
        }
        
        if !isUploading {
            streamHandler.setEvent(FlutterEndOfEventStream)
        }
    }
    
    private func download(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? Dictionary<String, Any>,
              let cloudFileName = args["cloudFileName"] as? String,
              let localFilePath = args["localFilePath"] as? String,
              let watchUpdate = args["watchUpdate"] as? Bool
        else {
            result(argumentError)
            return
        }
        
        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: containerId)
        else {
            result(containerError)
            return
        }
        DebugHelper.log("containerURL: \(containerURL.path)")
        
        let cloudFileURL = containerURL.appendingPathComponent(cloudFileName)
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: cloudFileURL)
            if !watchUpdate { result(nil) }
        } catch {
            result(nativeCodeError(error))
        }
        
        if watchUpdate, let messenger = self.messenger {
            let query = NSMetadataQuery.init()
            query.operationQueue = .main
            query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
            query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemPathKey, cloudFileURL.path)
            
            let downloadEventChannel = FlutterEventChannel(name: "icloud/event/download/\(cloudFileName)", binaryMessenger: messenger)
            let downloadStreamHandler = StreamHandler()
            downloadStreamHandler.onCancelHandler = { [self] in
                removeObservers(query)
                query.stop()
            }
            downloadEventChannel.setStreamHandler(downloadStreamHandler)
            
            let localFileURL = URL(fileURLWithPath: localFilePath)
            addDownloadObservers(query: query, cloudFileURL: cloudFileURL, localFileURL: localFileURL, streamHandler: downloadStreamHandler)
            
            result(nil)
            query.start()
        }
    }
    
    private func addDownloadObservers(query: NSMetadataQuery, cloudFileURL: URL, localFileURL: URL, streamHandler: StreamHandler) {
        NotificationCenter.default.addObserver(forName: NSNotification.Name.NSMetadataQueryDidFinishGathering, object: query, queue: query.operationQueue) { [self] (notification) in
            onDownloadQueryNotification(query: query, cloudFileURL: cloudFileURL, localFileURL: localFileURL, streamHandler: streamHandler)
        }
        
        NotificationCenter.default.addObserver(forName: NSNotification.Name.NSMetadataQueryDidUpdate, object: query, queue: query.operationQueue) { [self] (notification) in
            onDownloadQueryNotification(query: query, cloudFileURL: cloudFileURL, localFileURL: localFileURL, streamHandler: streamHandler)
        }
    }
    
    private func onDownloadQueryNotification(query: NSMetadataQuery, cloudFileURL: URL, localFileURL: URL, streamHandler: StreamHandler) {
        if query.results.count == 0 {
            return
        }
        
        guard let fileItem = query.results.first as? NSMetadataItem else { return }
        guard let fileURL = fileItem.value(forAttribute: NSMetadataItemURLKey) as? URL else { return }
        guard let fileURLValues = try? fileURL.resourceValues(forKeys: [.ubiquitousItemIsDownloadingKey, .ubiquitousItemDownloadingStatusKey]) else { return }
        
        if let error = fileURLValues.ubiquitousItemDownloadingError {
            streamHandler.setEvent(nativeCodeError(error))
            return
        }
        
        if let progress = fileItem.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? Double {
            streamHandler.setEvent(progress)
        }
        
        if fileURLValues.ubiquitousItemDownloadingStatus == URLUbiquitousItemDownloadingStatus.current {
            do {
                let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(cloudFileURL.lastPathComponent, isDirectory: false)
                try FileManager.default.copyItem(at: cloudFileURL, to: tempFile)
                _ = try FileManager.default.replaceItemAt(localFileURL, withItemAt: tempFile)
                streamHandler.setEvent(FlutterEndOfEventStream)
            } catch {
                streamHandler.setEvent(nativeCodeError(error))
            }
        }
    }
    
    private func delete(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? Dictionary<String, Any>,
              let cloudFileName = args["cloudFileName"] as? String
        else {
            result(argumentError)
            return
        }
        
        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: containerId)
        else {
            result(containerError)
            return
        }
        DebugHelper.log("containerURL: \(containerURL.path)")
        
        let cloudFileURL = containerURL.appendingPathComponent(cloudFileName)
        do {
            if FileManager.default.fileExists(atPath: cloudFileURL.path) {
                try FileManager.default.removeItem(at: cloudFileURL)
            }
            result(nil)
        } catch {
            result(nativeCodeError(error))
        }
    }
    
    private func removeObservers(_ query: NSMetadataQuery, watchUpdate: Bool = true){
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.NSMetadataQueryDidFinishGathering, object: query)
        if watchUpdate {
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name.NSMetadataQueryDidUpdate, object: query)
        }
    }
    
    let argumentError = FlutterError(code: "E_ARG", message: "Invalid Arguments", details: nil)
    let containerError = FlutterError(code: "E_CTR", message: "Invalid containerId, or user is not signed in, or user disabled iCould permission", details: nil)
    
    private func nativeCodeError(_ error: Error) -> FlutterError {
        return FlutterError(code: "E_NAT", message: "Native Code Error", details: "\(error)")
    }
}

class StreamHandler: NSObject, FlutterStreamHandler {
    private var _eventSink: FlutterEventSink?
    var onCancelHandler: (() -> Void)?
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        _eventSink = events
        DebugHelper.log("on listen")
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        onCancelHandler?()
        _eventSink = nil
        DebugHelper.log("on cancel")
        return nil
    }
    
    func setEvent(_ data: Any) {
        _eventSink?(data)
    }
}

class DebugHelper {
    public static func log(_ message: String) {
        #if DEBUG
        print(message)
        #endif
    }
}

extension NSMetadataItem {
    var url: URL? {
        return self.value(forAttribute: NSMetadataItemURLKey) as? URL
    }
    var creationDate: Date? {
        return self.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date
    }
    var modifiedDate: Date? {
        return self.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
    }
    var name: String? {
        return self.value(forAttribute: NSMetadataItemFSNameKey) as? String
    }
    var displayName: String? {
        return self.value(forAttribute: NSMetadataItemDisplayNameKey) as? String
    }
    var fileSize: Int? {
        return self.value(forAttribute: NSMetadataItemFSSizeKey) as? Int
    }
}

extension ISO8601DateFormatter {
    convenience init(_ formatOptions: Options) {
        self.init()
        self.formatOptions = formatOptions
    }
}

extension Formatter {
    static let iso8601WithFractrionalSeconds = ISO8601DateFormatter([.withInternetDateTime, .withFractionalSeconds])
}

extension Date {
    var iso8601WithFractrionalSeconds: String {
        return Formatter.iso8601WithFractrionalSeconds.string(from: self)
    }
}
