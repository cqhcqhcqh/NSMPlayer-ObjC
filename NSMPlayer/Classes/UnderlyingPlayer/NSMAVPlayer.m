// NSMAVPlayer.m
//
// Copyright (c) 2017 NSMPlayer
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

@import MediaPlayer;
@import Bolts;
@import Reachability;

#import "NSMAVPlayer.h"
#import "NSMAVPlayerView.h"
#import "NSMPlayerProtocol.h"
#import "NSMPlayerLogging.h"
#import "NSMPlayerAsset.h"
#import "NSMUnderlyingPlayer.h"

@interface NSMAVPlayer ()

@property (nonatomic, strong) id timeObserverToken;
@property (nonatomic, strong) BFTaskCompletionSource *prepareSource;
@property (nonatomic, strong) NSMPlayerAsset *currentAsset;
@property (nonatomic, strong) NSProgress *playbackProgress;
@property (nonatomic, strong) NSProgress *bufferProgress;
@property (nonatomic, strong) AVURLAsset *URLAsset;

@end

@implementation NSMAVPlayer

static void * NSMAVPlayerKVOContext = &NSMAVPlayerKVOContext;

@dynamic playerView, playerType ,playerError, currentStatus, autoPlay, loopPlayback, preload, allowWWAN;

#pragma mark - Properties

- (instancetype)init {
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(underlyingPlayerPlaybackStalling:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(underlyingPlayerPlaybackStalling:) name:UIApplicationWillResignActiveNotification object:nil];
        _playbackProgress = [NSProgress progressWithTotalUnitCount:0];
        _bufferProgress = [NSProgress progressWithTotalUnitCount:0];
    }
    return self;
}

- (void)underlyingPlayerPlaybackStalling:(NSNotification *)notification {
    [[NSNotificationCenter defaultCenter] postNotificationName:NSMUnderlyingPlayerPlaybackStallingNotification object:self userInfo:nil];
}

// Will attempt load and test these asset keys before playing
+ (NSArray *)assetKeysRequiredToPlay {
    return @[@"tracks", @"playable", @"hasProtectedContent"];
}

#pragma mark - Asset Loading

- (BFTask *)asynchronouslyLoadURLAsset:(AVURLAsset *)newAsset {
    __weak __typeof(self) weakself = self;
    BFTaskCompletionSource *source = [BFTaskCompletionSource taskCompletionSource];
    /**
     * Using AVAsset now runs the risk of blocking the current thread
     * (the main UI thread) whilst I/O happens to populate the
     * properties. It's prudent to defer our work until the properties
     * we need have been loaded.
     */
    [newAsset loadValuesAsynchronouslyForKeys:self.class.assetKeysRequiredToPlay completionHandler:^{
        __strong __typeof(weakself)strongself = weakself;
        
        /**
         * The asset invokes its completion handler on an arbitrary queue.
         * To avoid multiple threads using our internal state at the same time
         * we'll elect to use the main thread at all times, let's dispatch
         * our handler to the main queue.
         */
        dispatch_async(dispatch_get_main_queue(), ^{
            
            if (strongself.URLAsset != newAsset) {
                /*
                 self.asset has already changed! No point continuing because
                 another newAsset will come along in a moment.
                 */
                return;
            }
            /**
             * Test whether the values of each of the keys we need have been
             * successfully loaded.
             */
            for (NSString *key in strongself.class.assetKeysRequiredToPlay) {
                NSError *error = nil;
                AVKeyValueStatus status = [newAsset statusOfValueForKey:key error:&error];
                if (status == AVKeyValueStatusFailed) {
                    [source setError:error];
                    return;
                }
            }
            
            // We can't play this asset.
            if (!newAsset.playable || newAsset.hasProtectedContent) {
                [source setError:[NSError errorWithDomain:NSMUnderlyingPlayerErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey : @"Can't use this AVAsset because it isn't playable or has protected content"}]];
                return;
            }
            
            /**
             * We can play this asset. Create a new AVPlayerItem and make it
             * our player's current item.
             */
            [strongself setupAVPlayerWithAsset:newAsset prepareSource:source];
            
        });
    }];
    return source.task;
}

- (void)setupAVPlayerWithAsset:(AVAsset *)asset prepareSource:(BFTaskCompletionSource *)source {
    NSAssert([NSThread currentThread] == [NSThread mainThread], @"You should register for KVO change notifications and unregister from KVO change notifications on the main thread. ");
    
    [self removeTimeObserverToken];
    [self removeCurrentItemObserver];
    self.playbackProgress.completedUnitCount = self.playbackProgress.totalUnitCount = 0;
    self.bufferProgress.completedUnitCount = self.bufferProgress.totalUnitCount = 0;
    
    self.prepareSource = source;
    
    AVPlayerItem *playerItem = [AVPlayerItem playerItemWithAsset:asset];
    // ensure that this is done before the playerItem is associated with the player
    // Passing strings as key paths is strictly worse than using properties directly, as any typo or misspelling won’t be caught by the compiler, and will cause things to not work
    // Since @selector looks through all available selectors in the target, this won’t prevent all mistakes, but it will catch most of them—including breaking changes made by Xcode automatic refactoring
    [playerItem addObserver:self forKeyPath:NSStringFromSelector(@selector(status)) options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial context:NSMAVPlayerKVOContext];
    [playerItem addObserver:self forKeyPath:NSStringFromSelector(@selector(loadedTimeRanges)) options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial context:NSMAVPlayerKVOContext];
    [playerItem addObserver:self forKeyPath:@"playbackLikelyToKeepUp" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial context:NSMAVPlayerKVOContext];
    [playerItem addObserver:self forKeyPath:@"playbackBufferEmpty" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial context:NSMAVPlayerKVOContext];
    
    // Note that NSNotifications posted by AVPlayerItem may be posted on a different thread from the one on which the observer was registered.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerItemDidReachEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:playerItem];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerItemFailedToPlayToEndTime:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:playerItem];
    // Posted when some media did not arrive in time to continue playback.
    // The notification’s object is the AVPlayerItem instance whose playback was unable to continue because the necessary streaming media wasn’t delivered in a timely fashion over a network. Playback of streaming media continues once a sufficient amount of data is delivered. File-based playback does not continue.< i doubt that，File-based palyback also continue>
    
    // The notification’s object is the AVPlayerItem instance whose playback was unable to continue because the necessary streaming media wasn’t delivered in a timely fashion over a network.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerItemPlaybackStalled:) name:AVPlayerItemPlaybackStalledNotification object:playerItem];
    
    if (self.avplayer == nil) {
        self.avplayer = [[AVPlayer alloc] init];
    }
    
    [self.avplayer replaceCurrentItemWithPlayerItem:playerItem];
    
    // Invoke callback every one second
    [self addTimeObserverToken];
}

#pragma mark - NSMUnderlyingPlayerProtocol

/**
 * Preparing an Asset for Use
 * If you want to prepare an asset for playback, you should load its tracks property
 */
- (void)replaceCurrentAssetWithAsset:(NSMPlayerAsset *)asset {
    self.currentAsset = asset;
}

- (BFTask *)prepare {
    self.URLAsset = [AVURLAsset URLAssetWithURL:self.currentAsset.assetURL options:nil];
    return [self asynchronouslyLoadURLAsset:self.URLAsset];
}

- (void)play {
    [self.avplayer play];
}

- (void)pause {
    [self.avplayer pause];
}

- (void)setRate:(CGFloat)rate {
    self.avplayer.rate = rate;
}

- (BFTask *)seekToTime:(NSTimeInterval)seconds {
    /**
     'NSInvalidArgumentException', reason: 'AVPlayerItem cannot service a seek request with a completion handler until its status is AVPlayerItemStatusReadyToPlay.'
     */
    CMTime time = CMTimeMakeWithSeconds(seconds, NSEC_PER_SEC);
    BFTaskCompletionSource *tcs = [BFTaskCompletionSource taskCompletionSource];
    [self.avplayer seekToTime:time completionHandler:^(BOOL finished) {
        [tcs setResult:@(finished)];
    }];
    //workaround
    //    dispatch_async(dispatch_get_main_queue(), ^{
    //        self.playbackProgress.completedUnitCount = seconds;
    //    });
    return tcs.task;
}

/**
 * You should register for KVO change notifications and unregister from KVO change notifications on the main thread.
 * so releasePlayer method should invoke on the main thread
 */
- (void)releasePlayer {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self removeCurrentItemObserver];
        [self removeTimeObserverToken];
        [self.avplayer replaceCurrentItemWithPlayerItem:nil];
        self.avplayer = nil;
        self.playbackProgress.completedUnitCount = self.playbackProgress.totalUnitCount = 0;
        self.bufferProgress.completedUnitCount = self.bufferProgress.totalUnitCount = 0;
    });
}

- (void)setVolume:(CGFloat)volume {
    self.avplayer.volume = volume;
}

- (CGFloat)volume {
    return self.avplayer.volume;
}

- (void)setMuted:(BOOL)on {
    self.avplayer.muted = on;
}

- (BOOL)isMuted {
    return self.avplayer.isMuted;
}

- (CGSize)videoSize {
    AVAssetTrack *track = [[self.avplayer.currentItem.asset tracksWithMediaType:AVMediaTypeVideo] lastObject];
    CGSize size = [track naturalSize];
    return size;
}

- (CGFloat)rate {
    return self.avplayer.rate;
}

- (void)setPlayerView:(id<NSMVideoPlayerViewProtocol>)playerView {
    [playerView setPlayer:self.avplayer];
}

#pragma mark - NSKeyValueObserving

// AV Foundation does not specify what thread that the notification is sent on
// if you want to update the user interface, you must make sure that any relevant code is invoked on the main thread
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (context != NSMAVPlayerKVOContext) {
        // KVO isn't for us.
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    
    if ([keyPath isEqualToString:NSStringFromSelector(@selector(status))]) {
        AVPlayerItemStatus status = [change[NSKeyValueChangeNewKey] intValue];
        if (status == AVPlayerItemStatusReadyToPlay) {
            NSTimeInterval duration = CMTimeGetSeconds(self.avplayer.currentItem.duration);
            self.bufferProgress.totalUnitCount = self.playbackProgress.totalUnitCount = duration;
            [self.prepareSource setResult:@YES];
            self.prepareSource = nil;
        } else if (status == AVPlayerItemStatusFailed) {
            // If the receiver's status is AVPlayerStatusFailed, this describes the error that caused the failure
            NSMPlayerLogError(@"Player status failed: %@", self.avplayer.error);
            [self.prepareSource setError:self.avplayer.error];
            self.prepareSource = nil;
        }
    } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(loadedTimeRanges))]) {
        // The array contains NSValue objects containing a CMTimeRange value indicating the times ranges for which the player item has media data readily available. The time ranges returned may be discontinuous.
        NSArray *loadedTimeRanges = self.avplayer.currentItem.loadedTimeRanges;
        if (loadedTimeRanges) {
            for (NSValue *rangeValue in loadedTimeRanges) {
                CMTimeRange timeRange = [rangeValue CMTimeRangeValue];
                if (CMTimeRangeContainsTime(timeRange, CMTimeMakeWithSeconds(self.playbackProgress.completedUnitCount, NSEC_PER_SEC))) {
                    CGFloat rangeStartSeconds = CMTimeGetSeconds(timeRange.start);
                    CGFloat rangeDurationSeconds = CMTimeGetSeconds(timeRange.duration);
                    // keyPath loadedTimeRanges may change before keyPath status
                    if (self.bufferProgress.totalUnitCount > 0) {
                        self.bufferProgress.completedUnitCount = rangeStartSeconds + rangeDurationSeconds;
                    }
                    break;
                }
            }
        }
        
    } else if ([keyPath isEqualToString:@"playbackLikelyToKeepUp"]) {
        // Indicates whether the item will likely play through without stalling
        if (self.avplayer.currentItem.isPlaybackLikelyToKeepUp) {
            [[NSNotificationCenter defaultCenter] postNotificationName:NSMUnderlyingPlayerPlaybackLikelyToKeepUpNotification object:self userInfo:nil];
        }
    } else if ([keyPath isEqualToString:@"playbackBufferEmpty"]) {
        if (self.avplayer.currentItem.isPlaybackBufferEmpty) {
            // checkout network state
            if(![[Reachability reachabilityForInternetConnection] isReachable]) {
                [[NSNotificationCenter defaultCenter] postNotificationName:NSMUnderlyingPlayerFailedNotification object:self userInfo:@{NSMUnderlyingPlayerErrorKey : [NSError errorWithDomain:NSURLErrorDomain code:-1005 userInfo:@{NSLocalizedDescriptionKey : @"connection failed"}]}];
                [self.avplayer pause];
            } else {
                [[NSNotificationCenter defaultCenter] postNotificationName:NSMUnderlyingPlayerPlaybackBufferEmptyNotification object:self userInfo:nil];
            }
        }
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark - NSNotification

- (void)playerItemDidReachEnd:(NSNotification *)notification {
    [[NSNotificationCenter defaultCenter] postNotificationName:NSMUnderlyingPlayerDidPlayToEndTimeNotification object:self userInfo:nil];
}

- (void)playerItemFailedToPlayToEndTime:(NSNotification *)notification {
    NSMPlayerLogInfo(@"Player item failed to play to end time: %@",notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey]);
    [[NSNotificationCenter defaultCenter] postNotificationName:NSMUnderlyingPlayerFailedNotification object:self userInfo:@{NSMUnderlyingPlayerErrorKey : notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey]}];
}

- (void)playerItemPlaybackStalled:(NSNotification *)notification {
    NSMPlayerLogInfo(@"Player item playback stalled");
}

- (void)dealloc {
    [self removeTimeObserverToken];
    [self removeCurrentItemObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)removeTimeObserverToken {
    if (self.timeObserverToken) {
        [self.avplayer removeTimeObserver:self.timeObserverToken];
        self.timeObserverToken = nil;
    }
}

- (void)addTimeObserverToken {
    __weak __typeof(self) weakself = self;
    dispatch_queue_t mainQueue = dispatch_get_main_queue();
    self.timeObserverToken = [self.avplayer addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(1.0, NSEC_PER_SEC) queue:mainQueue usingBlock:^(CMTime time) {
        weakself.playbackProgress.completedUnitCount = CMTimeGetSeconds(time);
        NSMPlayerLogInfo(@"Player item playback progress: %lld", weakself.playbackProgress.completedUnitCount);
    }];
}

- (void)removeCurrentItemObserver {
    if (self.avplayer.currentItem) {
        
        NSAssert([NSThread currentThread] == [NSThread mainThread], @"You should register for KVO change notifications and unregister from KVO change notifications on the main thread. ");
        [self.avplayer.currentItem removeObserver:self forKeyPath:NSStringFromSelector(@selector(status)) context:NSMAVPlayerKVOContext];
        [self.avplayer.currentItem removeObserver:self forKeyPath:NSStringFromSelector(@selector(loadedTimeRanges)) context:NSMAVPlayerKVOContext];
        [self.avplayer.currentItem removeObserver:self forKeyPath:@"playbackLikelyToKeepUp" context:NSMAVPlayerKVOContext];
        [self.avplayer.currentItem removeObserver:self forKeyPath:@"playbackBufferEmpty" context:NSMAVPlayerKVOContext];
        
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:self.avplayer.currentItem];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:self.avplayer.currentItem];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemPlaybackStalledNotification object:self.avplayer.currentItem];
    }
}

- (void)setPlayerRenderView:(id<NSMVideoPlayerViewProtocol>)playerRenderView {
    [playerRenderView setPlayer:self];
}

- (UIImage *)thumnailImageWithTime:(CMTime)requestTime {
    AVAsset *myAsset = self.avplayer.currentItem.asset;
    if ([[myAsset tracksWithMediaType:AVMediaTypeVideo] count] > 0) {
        AVAssetImageGenerator *imageGenerator = [AVAssetImageGenerator assetImageGeneratorWithAsset:myAsset];
        NSError *error;
        CMTime actualTime;
        CGImageRef halfWayImage = [imageGenerator copyCGImageAtTime:requestTime actualTime:&actualTime error:&error];
        if (halfWayImage != NULL) {
            return [UIImage imageWithCGImage:halfWayImage];
        }
    }
    return nil;
}

@end
