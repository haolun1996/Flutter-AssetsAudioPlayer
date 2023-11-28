#if canImport(UIKit)
import Flutter
import AVFoundation
import UIKit
#elseif os(OSX)
import FlutterMacOS
#endif

import MediaPlayer

public class Player : NSObject, AVAudioPlayerDelegate {
    
    let channel: FlutterMethodChannel
    let registrar: FlutterPluginRegistrar
    var player: AVQueuePlayer?
    
    var observerStatus: [NSKeyValueObservation] = []
    
    var _playingPath: String?
    var _lastOpenedPath: String?
    var audioFocusStrategy: AudioFocusStrategy = AudioFocusStrategy.None()
    
    var _loopSingleAudio = false
    var isLiveStream: Bool = false
    
    init(channel: FlutterMethodChannel, registrar: FlutterPluginRegistrar) {
        self.channel = channel
        self.registrar = registrar
    }
    
    func log(_ message: String){
        channel.invokeMethod("log", arguments: message)
    }
    
    func getUrlByType(path: String, audioType: String, assetPackage: String?) -> URL? {
        var url : URL
        
        if(audioType == "network" || audioType == "liveStream"){
            if let u = URL(string: path) {
                return u
            } else {
                print("Couldn't parse myURL = \(path)")
                return nil
            }
            
        } else if(audioType == "file"){
            var localPath = path

            if(!localPath.starts(with: "file://")){ //if already starts with "file://", do not add
                localPath = "file://" + localPath
            }
            let urlStr : String = localPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
            if let u = URL(string: urlStr) {
                print(u)
                return u
            } else {
                print("Couldn't parse myURL = \(urlStr)")
                return nil
            }
        }  else { //asset
            #if os(iOS) //for now it's not available on mac, we will make a copy from flutter of the asset to tmp file
            var assetKey: String
            if(assetPackage != nil && !assetPackage!.isEmpty){
                assetKey = self.registrar.lookupKey(forAsset: path, fromPackage: assetPackage!)
            } else {
                assetKey = self.registrar.lookupKey(forAsset: path)
            }
            
            guard let path = Bundle.main.path(forResource: assetKey, ofType: nil) else {
                return nil
            }
            
            url = URL(fileURLWithPath: path)
            return url
            #else
            return nil
            #endif
        }
    }
    
    #if os(iOS)
    func getAudioCategory(respectSilentMode: Bool) ->  AVAudioSession.Category {
        if(respectSilentMode) {
            return AVAudioSession.Category.soloAmbient
        } else {
            return AVAudioSession.Category.playback
        }
    }
    #endif
    
    #if os(iOS)
    var targets: [String:Any] = [:]
    
    func invokeListenerPlayPause(){
        self.channel.invokeMethod(Music.METHOD_PLAY_OR_PAUSE, arguments: [])
    }
    
    var nowPlayingInfo = [String: Any]()
    #endif
    
    class SlowMoPlayerItem: AVPlayerItem {
        
        override var canPlaySlowForward: Bool {
            return true
        }
        
        override var canPlayReverse: Bool {
            return true
        }
        
        override var canPlayFastForward: Bool {
            return true
        }
        
        override var canPlayFastReverse: Bool {
            return true
        }
        
        override var canPlaySlowReverse: Bool {
            return true
        }
    }
    
    var currentSongDurationMs : Float64 = Float64(0.0)
    
    func open(assetPath: String,
              assetPackage: String?,
              audioType: String,
              autoStart: Bool,
              volume: Double,
              seek: Int?,
              respectSilentMode: Bool,
              audioFocusStrategy: AudioFocusStrategy,
              playSpeed: Double,
              networkHeaders: NSDictionary?,
              result: @escaping FlutterResult
    ){
        self.stop()
        guard let url = self.getUrlByType(path: assetPath, audioType: audioType, assetPackage: assetPackage) else {
            log("resource not found \(assetPath)")
            result("")
            return
        }
        
        do {
            #if os(iOS)
            let category = getAudioCategory(respectSilentMode: respectSilentMode)
            let mode = AVAudioSession.Mode.default
            
            
            print("category " + category.rawValue)
            print("mode " + mode.rawValue)
            
            print("url: " + url.absoluteString)
            
            /* set session category and mode with options */
            if #available(iOS 10.0, *) {
                //try AVAudioSession.sharedInstance().setCategory(category, mode: mode, options: [.mixWithOthers])
                try AVAudioSession.sharedInstance().setCategory(category, mode: .default, options: [])
                try AVAudioSession.sharedInstance().setActive(true)
            } else {
                
                try AVAudioSession.sharedInstance().setCategory(category)
                try AVAudioSession.sharedInstance().setActive(true)
                
            }
            #endif
            
            var item : SlowMoPlayerItem
            if networkHeaders != nil && networkHeaders!.count > 0 {
                let asset = AVURLAsset(url: url, options: [
                    "AVURLAssetHTTPHeaderFieldsKey": networkHeaders!,
                    "AVURLAssetOutOfBandMIMETypeKey": "audio/mpeg"
                ])
                item = SlowMoPlayerItem(asset: asset)
            } else {
                item = SlowMoPlayerItem(url: url)
            }
            item.audioTimePitchAlgorithm = .timeDomain
            self.player = AVQueuePlayer(playerItem: item)
            
            self.audioFocusStrategy = audioFocusStrategy
            
            self._lastOpenedPath = assetPath
            
            self.setBuffering(true)
            self.isLiveStream = false
            observerStatus.append( item.observe(\.status, changeHandler: { [weak self] (item, value) in
                
                switch item.status {
                case .unknown:
                    debugPrint("status: unknown")
                case .readyToPlay:
                    debugPrint("status: ready to play")
                    
                    if(audioType == "liveStream"){
                        self?.channel.invokeMethod(Music.METHOD_CURRENT, arguments: ["totalDurationMs": 0.0])
                        self?.currentSongDurationMs = Float64(0.0)
                        self?.isLiveStream = true
                    } else {
                        let audioDurationMs = self?.getMillisecondsFromCMTime(item.duration) ?? 0
                        self?.channel.invokeMethod(Music.METHOD_CURRENT, arguments: ["totalDurationMs": audioDurationMs])
                        self?.currentSongDurationMs = audioDurationMs
                    }
                    
                    self?.setPlaySpeed(playSpeed: playSpeed)
                    
                    if(autoStart == true){
                        self?.play()
                    }
                    
                    self?.setVolume(volume: volume)
                  
                    
                    if(seek != nil){
                        self?.seek(to: seek!)
                    }
                    
                    self?._playingPath = assetPath
                    //self?.setBuffering(false)
                    
                    self?.addPostPlayingBufferListeners(item: item)
                    self?.addPlayerStatusListeners(item: (self?.player)!);
                    
                    result(nil)
                case .failed:
                    debugPrint("playback failed")
                    
                    self?.stop()
                    
                    result(FlutterError(
                        code: "PLAY_ERROR",
                        message: "Cannot play "+assetPath,
                        details: item.error?.localizedDescription)
                    )
                @unknown default:
                    fatalError()
                }
            }))
            
            
            
            if(self.player == nil){
                //log("player is null")
                return
            }
            
            self.currentTimeMs = 0.0
            self.playing = false
        } catch let error {
            result(FlutterError(
                code: "PLAY_ERROR",
                message: "Cannot play "+assetPath,
                details: error.localizedDescription)
            )
            log(error.localizedDescription)
            print(error.localizedDescription)
        }
    }
    
    // Getting error from Notification payload
    @objc func newErrorLogEntry(_ notification: Notification) {
        guard let object = notification.object, let playerItem = object as? AVPlayerItem else {
            return
        }
        guard let errorLog: AVPlayerItemErrorLog = playerItem.errorLog() else {
            return
        }
        NSLog("Error: \(errorLog)")
    }
    
    @objc func failedToPlayToEndTime(_ notification: Notification) {
        //Format errors    Playlist format error, Key format error, Session data format error    AVErrorFailedToParse
        //Live playlist update errors    Must update live playlist in time as per HLS Spec    AVErrorContentNotUpdated
        if let error : NSError = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError {
            //Network / Timeout errors    HTTP 4xx errors, HTTP 5xx errors, TCP/IP, DNS errors    AVErrorContentIsUnavailable, AVErrorNoLongerPlayable
            if(error.code == -11863 /*AVErrorContentIsUnavailable*/ || error.code == -11867 /* AVErrorNoLongerPlayable*/ ){
                self.onError(NetworkError(message: "avplayer http error"));
            }
            else {
                self.onError(PlayerError(message: "avplayer error"));
            }
        }
    }
    
    private func addPostPlayingBufferListeners(item : SlowMoPlayerItem){
        observerStatus.append( item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] (value, _) in
            // show buffering
            if(value.isPlaybackBufferEmpty){
             self?.setBuffering(true)
            }else{
            self?.setBuffering(false)
            }
        })
        
        observerStatus.append( item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] (_, _) in
            // hide buffering
            self?.setBuffering(false)
        })
        
        observerStatus.append( item.observe( \.isPlaybackBufferFull, options: [.new]) { [weak self] (_, _) in
            // hide buffering
            self?.setBuffering(false)
        })
    }
    
    
    private func addPlayerStatusListeners(item : AVQueuePlayer){
        if #available(iOS 10.0, OSX 10.12, *){
            observerStatus.append( item.observe(\.timeControlStatus, options: [.new]) { [weak self] (value, _) in
                // show buffering
                if(value.timeControlStatus == AVPlayer.TimeControlStatus.playing){
                    self?.playing = true;
                }else if(value.timeControlStatus == AVPlayer.TimeControlStatus.paused){
                    self?.playing = false;
                }else{
                    self?.playing = false;
                }
            })
        }
    }
    
    func getMillisecondsFromCMTime(_ time: CMTime) -> Double {
        let seconds = CMTimeGetSeconds(time);
        let milliseconds = seconds * 1000;
        return milliseconds;
    }
    
    func getSecondsFromCMTime(_ time: CMTime) -> Double {
        return self.getMillisecondsFromCMTime(time) / 1000;
    }
    
    @objc func handleInterruption(_ notification: Notification) {
        #if os(iOS)
        if(!self.audioFocusStrategy.request) {
            return
        }
        
        guard let userInfo = notification.userInfo,
            let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return
        }
        
        // Switch over the interruption type.
        switch type {
            
        case .began:
            // An interruption began. Update the UI as needed.
            pause()
            
        case .ended:
            // An interruption ended. Resume playback, if appropriate.
            
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                if(self.audioFocusStrategy.resumeAfterInterruption) {
                    self.invokeListenerPlayPause()
                }
                // Interruption ended. Playback should resume.
            } else {
                // Interruption ended. Playback should not resume.
            }
            
        default: ()
        }
        #endif
    }
    
    private func setBuffering(_ value: Bool){
        self.channel.invokeMethod(Music.METHOD_IS_BUFFERING, arguments: value)
    }
    
    func seek(to: Int){
        let targetTime = CMTimeMakeWithSeconds(Double(to) / 1000.0, preferredTimescale: 1)
        self.player?.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    
    func setVolume(volume: Double){
        self.player?.volume = Float(volume)
        self.channel.invokeMethod(Music.METHOD_VOLUME, arguments: volume)
    }
    
    private func onError(_ error: AssetAudioPlayerError){
        self.channel.invokeMethod(Music.METHOD_ERROR, arguments: [
            "type" : error.type,
            "message" : error.message,
        ])
    }
    
    var _rate : Float = 1.0
    var rate : Float {
        get {
            return _rate
        }
        set(newValue) {
            if(_rate != newValue){
                _rate = newValue
                self.channel.invokeMethod(Music.METHOD_PLAY_SPEED, arguments: _rate)
            }
        }
    }
    
    func setPlaySpeed(playSpeed: Double){
        self.rate = Float(playSpeed)
        if(self._playing){
            self.player?.rate = self.rate
        }
    }
    
    func forwardRewind(speed: Double){
        //on ios we can have nevative speed
        self.player?.rate = Float(speed) //it does not changes self.rate here
        
        self.channel.invokeMethod(Music.METHOD_FORWARD_REWIND, arguments: speed)
    }
    
    func stop(){
        self.player?.pause()
        self.player?.rate = 0.0
        
        self.player?.seek(to: CMTime.zero)
        self.playing = false
        self.currentTimeTimer?.invalidate()
        
        self.observerStatus.forEach {
            $0.invalidate()
        }
        self.observerStatus.removeAll()
        #if os(iOS)
        self.nowPlayingInfo.removeAll()
        #endif
        self.player = nil
    }
    
    func play(){
        if #available(iOS 10.0, macOS 10.12, *) {
            self.player?.playImmediately(atRate: self.rate)
        } else {
            self.player?.play()
            self.player?.rate = self.rate
        }
        self.currentTimeTimer = Timer.scheduledTimer(timeInterval: 0.3, target: self, selector: #selector(updateTimer), userInfo: nil, repeats: true)
        self.currentTimeTimer?.fire()
//        self.playing = true
        
    }
    
    private var looper: Any?
    
    func loopSingleAudio(loop: Bool) {
        _loopSingleAudio = loop
        
        let currentPosMillis = self._currentTime
        
        if(loop){
            #if os(iOS)
            if #available(iOS 10.0, *) {
                if let player = self.player {
                    if(!player.items().isEmpty){
                        self.looper = AVPlayerLooper(player: player, templateItem: player.items()[0])
                    }
                }
            }
            #elseif os(OSX)
            if #available(OSX 10.12, *) {
                if let player = self.player {
                    if(player.items().isEmpty){
                        self.looper = AVPlayerLooper(player: player, templateItem: player.items()[0])
                    }
                }
            }
            #endif
        } else {
            #if os(iOS)
            if #available(iOS 10.0, *) {
                (self.looper as? AVPlayerLooper)?.disableLooping()
                self.looper = nil
            }
            #elseif os(OSX)
            if #available(OSX 10.12, *) {
                (self.looper as? AVPlayerLooper)?.disableLooping()
                self.looper = nil
            }
            #endif
        }
        seek(to: Int(currentPosMillis))
    }
    
    var _currentTime : Double = 0.0
    
    private var currentTimeMs : Double {
        get {
            return _currentTime
        }
        set(newValue) {
            if(_currentTime != newValue){
                _currentTime = newValue
                self.channel.invokeMethod(Music.METHOD_POSITION, arguments: newValue)
            }
        }
    }
    
    func updateCurrentTime(time: CMTime){
        self.currentTimeMs = self.getMillisecondsFromCMTime(time)
    }
    
    var _playing : Bool = false
    var playing : Bool {
        get {
            return _playing
        }
        set(newValue) {
            _playing = newValue
            self.channel.invokeMethod(Music.METHOD_IS_PLAYING, arguments: self._playing)
        }
    }
    
    var currentTimeTimer: Timer?
    
    @objc public func playerDidFinishPlaying(note: NSNotification){
        if(self._loopSingleAudio){
            self.player?.seek(to: CMTime.zero)
            self.player?.play()
        } else {
            playing = false
            self.channel.invokeMethod(Music.METHOD_FINISHED, arguments: true)
        }
    }
    
    func pause(){
        self.player?.pause()
        
//        self.playing = false
        self.currentTimeTimer?.invalidate()
    }
    
    @objc func updateTimer(){
        //log("updateTimer")
        if let p = self.player {
            if let currentItem = p.currentItem {
                self.updateCurrentTime(time: currentItem.currentTime())
            }
        }
    }
}

class Music : NSObject, FlutterPlugin {
    
    static let METHOD_POSITION = "player.position"
    static let METHOD_FINISHED = "player.finished"
    static let METHOD_IS_PLAYING = "player.isPlaying"
    static let METHOD_FORWARD_REWIND = "player.forwardRewind"
    static let METHOD_CURRENT = "player.current"
    static let METHOD_VOLUME = "player.volume"
    static let METHOD_IS_BUFFERING = "player.isBuffering"
    static let METHOD_PLAY_SPEED = "player.playSpeed"
    static let METHOD_NEXT = "player.next"
    static let METHOD_PREV = "player.prev"
    static let METHOD_PLAY_OR_PAUSE = "player.playOrPause"
    static let METHOD_ERROR = "player.error"
    
    var players = Dictionary<String, Player>()
    
    func getOrCreatePlayer(id: String) -> Player {
        if let player = players[id] {
            return player
        } else {
            #if os(iOS)
            let newPlayer = Player(
                channel: FlutterMethodChannel(name: "assets_audio_player/"+id, binaryMessenger: registrar.messenger()),
                registrar: self.registrar
            )
            #else
            let newPlayer = Player(
                channel: FlutterMethodChannel(name: "assets_audio_player/"+id, binaryMessenger: registrar.messenger),
                registrar: self.registrar
            )
            #endif
            players[id] = newPlayer
            return newPlayer
        }
    }
    
    static func register(with registrar: FlutterPluginRegistrar) {
        
    }
    
    //public func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [AnyHashable : Any] = [:]) -> Bool {
    //    application.beginReceivingRemoteControlEvents()
    //    return true
    //}
    
    let channel: FlutterMethodChannel
    let registrar: FlutterPluginRegistrar
    
    init(messenger: FlutterBinaryMessenger, registrar: FlutterPluginRegistrar) {
        self.channel = FlutterMethodChannel(name: "assets_audio_player", binaryMessenger: messenger)
        self.registrar = registrar
    }
    
    func start(){
        #if os(iOS)
        self.registrar.addApplicationDelegate(self)
        #endif
        
        channel.setMethodCallHandler({(call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
            //self.log(call.method + call.arguments.debugDescription)
            switch(call.method){
            case "isPlaying" :
                guard let args = call.arguments as? NSDictionary else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments must be an NSDictionary",
                        details: nil)
                    )
                    break
                }
                guard let id = args["id"] as? String else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments[id] must be a String",
                        details: nil)
                    )
                    break
                }
                result(self.getOrCreatePlayer(id: id).playing)
                
            case "play" :
                guard let args = call.arguments as? NSDictionary else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments must be an NSDictionary",
                        details: nil)
                    )
                    break
                }
                guard let id = args["id"] as? String else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments[id] must be a String",
                        details: nil)
                    )
                    break
                }
                self.getOrCreatePlayer(id: id)
                    .play()
                result(true)
                
            case "pause" :
                guard let args = call.arguments as? NSDictionary else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments must be an NSDictionary",
                        details: nil)
                    )
                    break
                }
                guard let id = args["id"] as? String else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments[id] must be a String",
                        details: nil)
                    )
                    break
                }
                self.getOrCreatePlayer(id: id)
                    .pause()
                result(true)
                
            case "stop" :
                guard let args = call.arguments as? NSDictionary else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments must be an NSDictionary",
                        details: nil)
                    )
                    break
                }
                guard let id = args["id"] as? String else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments[id] must be a String",
                        details: nil)
                    )
                    break
                }
                
                self.getOrCreatePlayer(id: id)
                    .stop()
                result(true)
                
            case "seek" :
                guard let args = call.arguments as? NSDictionary else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments must be an NSDictionary",
                        details: nil)
                    )
                    break
                }
                guard let id = args["id"] as? String else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments[id] must be a String",
                        details: nil)
                    )
                    break
                }
                guard let pos = args["to"] as? Int else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments[to] must be a String",
                        details: nil)
                    )
                    break
                }
                self.getOrCreatePlayer(id: id)
                    .seek(to: pos)
                result(true)
            case "volume" :
                guard let args = call.arguments as? NSDictionary else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments must be an NSDictionary",
                        details: nil)
                    )
                    break
                }
                guard let id = args["id"] as? String else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments[id] must be a String",
                        details: nil)
                    )
                    break
                }
                guard let volume = args["volume"] as? Double else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments[volume] must be a Double",
                        details: nil)
                    )
                    break
                }
                self.getOrCreatePlayer(id: id)
                    .setVolume(volume: volume)
                result(true)
                
            case "playSpeed" :
                guard let args = call.arguments as? NSDictionary else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments must be an NSDictionary",
                        details: nil)
                    )
                    break
                }
                guard let id = args["id"] as? String else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments[id] must be a String",
                        details: nil)
                    )
                    break
                }
                guard let playSpeed = args["playSpeed"] as? Double else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments[playSpeed] must be a String",
                        details: nil)
                    )
                    break
                }
                self.getOrCreatePlayer(id: id)
                    .setPlaySpeed(playSpeed: playSpeed)
                result(true)
                
            case "loopSingleAudio" :
                guard let args = call.arguments as? NSDictionary else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments must be an NSDictionary",
                        details: nil)
                    )
                    break
                }
                guard let id = args["id"] as? String else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments[id] must be a String",
                        details: nil)
                    )
                    break
                }
                guard let loop = args["loop"] as? Bool else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments[loop] must be a Bool",
                        details: nil)
                    )
                    break
                }
                self.getOrCreatePlayer(id: id)
                    .loopSingleAudio(loop: loop)
                result(true)
                
            case "forwardRewind" :
                guard let args = call.arguments as? NSDictionary else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments must be an NSDictionary",
                        details: nil)
                    )
                    break
                }
                guard let id = args["id"] as? String else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments[id] must be a String",
                        details: nil)
                    )
                    break
                }
                guard let speed = args["speed"] as? Double else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments[speed] must be a String",
                        details: nil)
                    )
                    break
                }
                self.getOrCreatePlayer(id: id)
                    .forwardRewind(speed: speed)
                result(true)
                
            case "open" :
                guard let args = call.arguments as? NSDictionary else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments must be an NSDictionary",
                        details: nil)
                    )
                    break
                }
                guard let id = args["id"] as? String else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments[id] must be a String",
                        details: nil)
                    )
                    break
                }
                guard let assetPath = args["path"] as? String else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments[path] must be a String",
                        details: nil)
                    )
                    break
                }
                
                let assetPackage = args["package"] as? String //can be null
                
                guard let audioType = args["audioType"] as? String else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments[audioType] must be a String",
                        details: nil)
                    )
                    break
                }
                guard let volume = args["volume"] as? Double else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments[volume] must be a Double",
                        details: nil)
                    )
                    break
                }
                let seek = args["seek"] as? Int //can be null
                guard let playSpeed = args["playSpeed"] as? Double else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments[playSpeed] must be a Double",
                        details: nil)
                    )
                    break
                }
                guard let autoStart = args["autoStart"] as? Bool else {
                    result(FlutterError(
                        code: "METHOD_CALL",
                        message: call.method + " Arguments[autoStart] must be a Bool",
                        details: nil)
                    )
                    break
                }
                
                let networkHeaders = args["networkHeaders"] as? NSDictionary
                
                let respectSilentMode = args["respectSilentMode"] as? Bool ?? false
                
                let audioFocusStrategy = parseAudioFocusStrategy(args["audioFocusStrategy"] as? NSDictionary)
                
                self.getOrCreatePlayer(id: id)
                    .open(
                        assetPath: assetPath,
                        assetPackage: assetPackage,
                        audioType: audioType,
                        autoStart: autoStart,
                        volume:volume,
                        seek: seek,
                        respectSilentMode: respectSilentMode,
                        audioFocusStrategy: audioFocusStrategy,
                        playSpeed: playSpeed,
                        networkHeaders: networkHeaders,
                        result: result
                )
                
            default:
                result(FlutterMethodNotImplemented)
                break
                
            }
        })
    }
    
}

class AssetAudioPlayerError {
    let type: String
    let message: String
    init(type: String, message: String) {
        self.type = type
        self.message = message
    }
}

class NetworkError : AssetAudioPlayerError {
    init(message: String) {
        super.init(type: "network", message: message)
    }
}
class PlayerError : AssetAudioPlayerError {
    init(message: String) {
        super.init(type: "player", message: message)
    }
}

class AudioFocusStrategy {
    let request: Bool
    let resumeAfterInterruption: Bool
    let resumeOthersPlayersAfterDone: Bool
    
    private init(request: Bool, resumeAfterInterruption: Bool, resumeOthersPlayersAfterDone: Bool) {
        self.request = request
        self.resumeAfterInterruption = resumeAfterInterruption
        self.resumeOthersPlayersAfterDone = resumeOthersPlayersAfterDone
    }
    
    static func None() -> AudioFocusStrategy {
        return AudioFocusStrategy(request: false, resumeAfterInterruption: false, resumeOthersPlayersAfterDone: false)
    }
    static func Request(resumeAfterInterruption: Bool, resumeOthersPlayersAfterDone: Bool) -> AudioFocusStrategy {
        return AudioFocusStrategy(request: true, resumeAfterInterruption: resumeAfterInterruption, resumeOthersPlayersAfterDone: resumeOthersPlayersAfterDone)
    }
}

func parseAudioFocusStrategy(_ from: NSDictionary?) -> AudioFocusStrategy {
    if let params = from {
        let request = params["request"] as? Bool ?? false
        if (request == false) {
            return AudioFocusStrategy.None()
        }
        else {
            return AudioFocusStrategy.Request(
                resumeAfterInterruption: params["resumeAfterInterruption"] as? Bool ?? false,
                resumeOthersPlayersAfterDone: params["resumeOthersPlayersAfterDone"] as? Bool ?? false
            )
        }
    } else {
        return  AudioFocusStrategy.None()
    }
}