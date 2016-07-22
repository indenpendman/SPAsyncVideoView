//
//  SPAsyncVideoView.m
//  Pods
//
//  Created by Sergey Pimenov on 14/07/16.
//
//

#import "SPAsyncVideoView.h"

#import "SPAsyncVideoAsset.h"

#import <AVFoundation/AVFoundation.h>

@interface SPAsyncVideoView ()

@property (atomic, strong) dispatch_queue_t workingQueue;
@property (atomic, strong) AVAssetReader *assetReader;
@property (atomic, assign) BOOL canRenderAsset;

@end

@implementation SPAsyncVideoView

#pragma mark - Public API

- (instancetype)init {
    self = [super init];

    if (self) {
        [self commonInit];
    }

    return self;
}

- (void)awakeFromNib {
    [self commonInit];
}

- (void)setAsset:(nullable SPAsyncVideoAsset *)asset {
    NSAssert([NSThread mainThread] == [NSThread mainThread], @"Thread checker");

    if ([_asset isEqual:asset]) {
        return;
    }

    if (asset == nil) {
        _asset = nil;
        [self stopVideo];
        return;
    }

    if (_asset != nil) {
        [self flushAndStopReading];
    }

    _asset = asset;

    if (self.autoPlay) {
        [self playVideo];
    }
}

- (void)setVideoGravity:(SPAsyncVideoViewVideoGravity)videoGravity {
    if (_videoGravity == videoGravity) {
        return;
    }

    _videoGravity = videoGravity;

    AVSampleBufferDisplayLayer *displayLayer = [self displayLayer];

    switch (videoGravity) {
        case SPAsyncVideoViewVideoGravityResize:
            displayLayer.videoGravity = AVLayerVideoGravityResize;
            break;
        case SPAsyncVideoViewVideoGravityResizeAspect:
            displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
            break;
        case SPAsyncVideoViewVideoGravityResizeAspectFill:
            displayLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
            break;
        default:
            break;
    }
}

- (void)playVideo {
    NSAssert([NSThread mainThread] == [NSThread mainThread], @"Thread checker");

    __weak typeof (self) weakSelf = self;

    SPAsyncVideoAsset *asset = self.asset;
    dispatch_async(self.workingQueue, ^{
        [weakSelf setupWithAsset:asset];
    });
}

- (void)stopVideo {
    NSAssert([NSThread mainThread] == [NSThread mainThread], @"Thread checker");

    __weak typeof (self) weakSelf = self;
    dispatch_async(self.workingQueue, ^{
        [weakSelf flushAndStopReading];
    });
}

#pragma mark - Private API

- (void)flush {
    if ([self.delegate respondsToSelector:@selector(asyncVideoViewWillFlush:)]) {
        [self.delegate asyncVideoViewWillFlush:self];
    }

    AVSampleBufferDisplayLayer *displayLayer = [self displayLayer];

    [displayLayer stopRequestingMediaData];
    [displayLayer flushAndRemoveImage];

    if ([self.delegate respondsToSelector:@selector(asyncVideoViewDidFlush:)]) {
        [self.delegate asyncVideoViewDidFlush:self];
    }
}

- (void)flushAndStopReading {
    if (self.assetReader.status == AVAssetReaderStatusReading) {
        [self.assetReader cancelReading];
        self.assetReader = nil;
    }

    [self flush];
}

- (void)forceRestart {
    SPAsyncVideoAsset *asset = self.asset;
    __weak typeof (self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        weakSelf.asset = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.asset = asset;
        });
    });
}

- (void)commonInit {
    self.workingQueue = dispatch_queue_create("com.com.SPAsyncVideoViewQueue", NULL);
    self.actionAtItemEnd = SPAsyncVideoViewActionAtItemEndRepeat;
    self.videoGravity = SPAsyncVideoViewVideoGravityResizeAspectFill;
    self.backgroundColor = [UIColor blackColor];
    self.autoPlay = YES;
    self.canRenderAsset = [UIApplication sharedApplication].applicationState != UIApplicationStateBackground;
    self.restartPlaybackOnEnteringForeground = YES;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillEnterForeground:)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
}

+ (Class)layerClass {
    return [AVSampleBufferDisplayLayer class];
}

- (AVSampleBufferDisplayLayer *)displayLayer {
    @synchronized (self) {
        return (AVSampleBufferDisplayLayer *)self.layer;
    }
}

- (void)setupWithAsset:(SPAsyncVideoAsset *)asset {
    if (asset == nil || asset.url == nil) {
        return;
    }

    if (asset.asset == nil) {
        NSParameterAssert(asset.url);
        asset.asset = [AVURLAsset assetWithURL:asset.url];
    }

    NSArray<NSString *> *keys = @[@"tracks", @"playable", @"duration"];

    __weak typeof (self) weakSelf = self;
    [self.asset.asset loadValuesAsynchronouslyForKeys:keys completionHandler:^{
        if (weakSelf.workingQueue == NULL) {
            return;
        }

        dispatch_async(weakSelf.workingQueue, ^{
            @synchronized (weakSelf) {
                SPAsyncVideoAsset *currentAsset = weakSelf.asset;
                AVURLAsset *currentAVAsset = currentAsset.asset;
                NSDictionary *outputSettings = currentAsset.outputSettings;

                if (currentAVAsset == nil || ![currentAsset isEqual:asset]) {
                    return;
                }

                [weakSelf setupWithAVURLAsset:currentAVAsset
                               outputSettings:outputSettings];
            }
        });
    }];
}

- (void)setupWithAVURLAsset:(AVURLAsset *)asset outputSettings:(NSDictionary *)outputSettings {
    NSError *error = nil;

    AVAssetReader *assetReader = [[AVAssetReader alloc] initWithAsset:(AVAsset *)asset
                                                                error:&error];

    if (error != nil) {
        [self notifyDelegateAboutError:error];
        return;
    }

    NSArray<AVAssetTrack *> *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    AVAssetTrack *videoTrack = videoTracks.firstObject;

    if (videoTrack == nil) {
        NSError *error = [NSError errorWithDomain:AVFoundationErrorDomain
                                             code:AVErrorOperationNotSupportedForAsset
                                         userInfo:nil];
        [self notifyDelegateAboutError:error];
        return;
    }

    AVAssetReaderTrackOutput *outVideo = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack
                                                                                    outputSettings:outputSettings];

    [assetReader addOutput:outVideo];

    [self startReadingWithReader:assetReader];
}

- (void)setCurrentControlTimebaseWithTime:(CMTime)time {
    AVSampleBufferDisplayLayer *displayLayer = [self displayLayer];

    CMTimebaseRef controlTimebase;
    CMTimebaseCreateWithMasterClock(CFAllocatorGetDefault(),
                                    CMClockGetHostTimeClock(),
                                    &controlTimebase);

    displayLayer.controlTimebase = controlTimebase;

    CMTimebaseSetTime(displayLayer.controlTimebase, time);
    CMTimebaseSetRate(displayLayer.controlTimebase, 1.);
}

- (void)startReadingWithReader:(AVAssetReader *)assetReader {
    AVAssetReaderTrackOutput *outVideo = (AVAssetReaderTrackOutput *)assetReader.outputs.firstObject;
    outVideo.supportsRandomAccess = YES;

    if (![assetReader startReading]) {
        NSError *error = [NSError errorWithDomain:AVFoundationErrorDomain
                                             code:AVErrorOperationNotSupportedForAsset
                                         userInfo:nil];
        [self notifyDelegateAboutError:error];
        return;
    }

    _assetReader = assetReader;

    [self setCurrentControlTimebaseWithTime:CMTimeMake(0., 1.)];

    __weak typeof (self) weakSelf = self;

    __block BOOL isFirstFrame = YES;
    [[self displayLayer] requestMediaDataWhenReadyOnQueue:self.workingQueue usingBlock:^{
        __strong typeof (weakSelf) strongSelf = weakSelf;

        AVSampleBufferDisplayLayer *displayLayer = [strongSelf displayLayer];

        if (!displayLayer.isReadyForMoreMediaData || displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
            return;
        }

        if (assetReader.status != AVAssetReaderStatusReading) {
            return;
        }

        if (!strongSelf.canRenderAsset) {
            return;
        }

        CMSampleBufferRef sampleBuffer = [outVideo copyNextSampleBuffer];
        if (sampleBuffer != NULL) {
            if (isFirstFrame && [strongSelf.delegate respondsToSelector:@selector(asyncVideoViewWillRenderFirstFrame:)]) {
                [strongSelf.delegate asyncVideoViewWillRenderFirstFrame:strongSelf];
            }

            [displayLayer enqueueSampleBuffer:sampleBuffer];
            CFRelease(sampleBuffer);

            if (isFirstFrame && [strongSelf.delegate respondsToSelector:@selector(asyncVideoViewDidRenderFirstFrame:)]) {
                [strongSelf.delegate asyncVideoViewDidRenderFirstFrame:strongSelf];
            }

            isFirstFrame = NO;

            return;
        }

        if ([strongSelf.delegate respondsToSelector:@selector(asyncVideoViewDidPlayToEnd:)]) {
            [strongSelf.delegate asyncVideoViewDidPlayToEnd:strongSelf];
        }

        switch (strongSelf.actionAtItemEnd) {
            case SPAsyncVideoViewActionAtItemEndNone: {
                [strongSelf flush];
                strongSelf.assetReader = nil;
                break;
            }
            case SPAsyncVideoViewActionAtItemEndRepeat: {
                @synchronized (outVideo.track) {
                    CMTimeRange timeRange = outVideo.track.timeRange;

                    if (!CMTimeRangeEqual(timeRange, kCMTimeRangeInvalid)) {
                        [displayLayer flush];
                        [strongSelf setCurrentControlTimebaseWithTime:CMTimeMake(0., 1.)];
                        NSValue *beginingTimeRangeValue = [NSValue valueWithCMTimeRange:outVideo.track.timeRange];
                        [outVideo resetForReadingTimeRanges:@[beginingTimeRangeValue]];
                        sampleBuffer = [outVideo copyNextSampleBuffer];
                        [displayLayer enqueueSampleBuffer:sampleBuffer];
                        CFRelease(sampleBuffer);
                    } else {
                        [strongSelf forceRestart];
                    }
                }
                break;
            }
            default:
                break;
        }
    }];
}

- (void)notifyDelegateAboutError:(nonnull NSError *)error {
    if ([self.delegate respondsToSelector:@selector(asyncVideoView:didOccurError:)]) {
        [self.delegate asyncVideoView:self didOccurError:error];
    }
}

- (void)applicationDidEnterBackground:(NSNotification *)notificaiton {
    self.canRenderAsset = NO;

    [self flushAndStopReading];
}

- (void)applicationWillEnterForeground:(NSNotification *)notification {
    self.canRenderAsset = YES;

    if (self.restartPlaybackOnEnteringForeground) {
        [self forceRestart];
    }
}

- (void)dealloc {
    if (self.assetReader.status == AVAssetReaderStatusReading) {
        [self.assetReader cancelReading];
    }

    AVSampleBufferDisplayLayer *displayLayer = [self displayLayer];
    [displayLayer stopRequestingMediaData];

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIApplicationDidEnterBackgroundNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIApplicationWillEnterForegroundNotification
                                                  object:nil];
}

@end
