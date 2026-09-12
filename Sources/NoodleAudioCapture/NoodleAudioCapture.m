#import "NoodleAudioCapture.h"

@implementation NoodleAudioCapture {
    AVAudioEngine *_engine;
    AVAudioInputNode *_input;
    BOOL _tapInstalled;
}

- (instancetype)initWithEngine:(AVAudioEngine *)engine {
    if ((self = [super init])) {
        _engine = engine;
    }
    return self;
}

- (BOOL)isRunning { return _tapInstalled && _engine.isRunning; }

- (BOOL)startWithBufferSize:(AVAudioFrameCount)bufferSize
                   handler:(AVAudioNodeTapBlock)handler
                     error:(NSError **)error {
    if (self.isRunning) { return YES; }
    // An asynchronous device-configuration change stops the engine but leaves
    // its tap installed. Replace that tap using the new format before restarting.
    [self stop];
    @try {
        _input = _engine.inputNode;
        // Device selection can change the hardware format while speech prepares.
        // Read the input scope immediately before installing, without an async gap.
        // The input node cannot convert; conversion belongs in the buffer consumer.
        AVAudioFormat *format = [_input inputFormatForBus:0];
        if (format.sampleRate <= 0 || format.channelCount == 0) {
            if (error) {
                *error = [NSError errorWithDomain:@"NoodleAudioCapture" code:1 userInfo:@{
                    NSLocalizedDescriptionKey: @"The microphone is still changing its audio format. Try recording again."
                }];
            }
            return NO;
        }
        [_input installTapOnBus:0 bufferSize:bufferSize format:format block:handler];
        _tapInstalled = YES;
        [_engine prepare];
        if (![_engine startAndReturnError:error]) {
            [self stop];
            return NO;
        }
        return YES;
    } @catch (NSException *exception) {
        [self stop];
        if (error) {
            *error = [NSError errorWithDomain:@"NoodleAudioCapture" code:2 userInfo:@{
                NSLocalizedDescriptionKey: @"The microphone changed or could not start. Try recording again.",
                NSLocalizedFailureReasonErrorKey: exception.reason ?: @"Audio input setup failed."
            }];
        }
        return NO;
    }
}

- (void)stop {
    if (!_tapInstalled) { return; }
    _tapInstalled = NO;
    // A disconnected device can also reject teardown. Never unwind into Swift.
    @try { [_engine stop]; } @catch (NSException *exception) {}
    @try { [_input removeTapOnBus:0]; } @catch (NSException *exception) {}
    _input = nil;
}

- (void)dealloc {
    [self stop];
}
@end
