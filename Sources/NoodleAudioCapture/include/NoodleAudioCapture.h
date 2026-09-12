#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN

/// Owns the tap so failed startup and repeated stops cannot remove an unowned tap.
/// AVAudioEngine raises Objective-C exceptions for changing hardware formats;
/// these must be caught before they can unwind through a Swift concurrency task.
@interface NoodleAudioCapture : NSObject
- (instancetype)initWithEngine:(AVAudioEngine *)engine;
- (BOOL)startWithBufferSize:(AVAudioFrameCount)bufferSize
                   handler:(AVAudioNodeTapBlock)handler
                     error:(NSError * _Nullable * _Nullable)error;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
