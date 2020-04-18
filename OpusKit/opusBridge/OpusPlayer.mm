#import "OpusPlayer.h"
#import "opusfile.h"
#import <AudioUnit/AudioUnit.h>
#import <map>
#import "NSObject+Lock.h"
#import "Queue.h"
#import "OpusAudioBuffer.h"
#include <os/lock.h>

#define kOutputBus 0
#define kInputBus 1

static const int OpusAudioPlayerBufferCount = 3;
static const int OpusAudioPlayerSampleRate = 48000; // libopusfile is bound to use 48 kHz

static SYNCHRONIZED_DEFINE(filledBuffersLock) = PTHREAD_MUTEX_INITIALIZER;
static os_unfair_lock audioPositionLock = OS_UNFAIR_LOCK_INIT;

static std::map<int, __weak OpusPlayer *> activeAudioPlayers;


@interface OpusPlayer () {
@public
    int _playerId;
    
    NSString *_filePath;
    NSInteger _fileSize;
    
    bool _isSeekable;
    int64_t _totalPcmDuration;
    
    bool _isPaused;
    
    OggOpusFile *_opusFile;
    AudioComponentInstance _audioUnit;
    
    OpusAudioBuffer *_filledAudioBuffers[OpusAudioPlayerBufferCount];
    int _filledAudioBufferCount;
    int _filledAudioBufferPosition;
    
    int64_t _currentPcmOffset;
    bool _finished;
}

@end

@implementation OpusPlayer

static Queue * queue;

+(void)initialize {
    queue = [[Queue alloc] initWithName:@"OpusPlayerQueue"];
}

+ (bool)canPlayFile:(NSString *)path {
    int error = OPUS_OK;
    OggOpusFile *file = op_test_file([path UTF8String], &error);
    if (file != NULL)
    {
        error = op_test_open(file);
        op_free(file);
        return error == OPUS_OK;
    }
    return false;
}

+ (NSTimeInterval)durationFile:(NSString *)path {
    int error = OPUS_OK;
    OggOpusFile *file = op_test_file([path UTF8String], &error);
    if (file != NULL)
    {
        float duration = 0;
        error = op_test_open(file);
        duration = op_pcm_total(file, -1);
        op_free(file);
        return duration / (NSTimeInterval)OpusAudioPlayerSampleRate;
    }
    return 0;
}

-(BOOL)isPaused {
    return _isPaused;
}

-(BOOL)isEqualToPath:(NSString *)path {
    return [_filePath isEqualToString:path];
}

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self != nil)
    {
        _filePath = path;
        
        static int nextPlayerId = 1;
        _playerId = nextPlayerId++;
        
        _isPaused = true;
        
        [queue dispatch:^{
            self->_fileSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil][NSFileSize] integerValue];
            if (self->_fileSize == 0)
            {
                NSLog(@"[OpusAudioPlayer#%p invalid file]", self);
                [self cleanupAndReportError];
            }
        }];

    }
    return self;
}

- (void)dealloc {
    [self cleanup];
}

- (void)cleanupAndReportError {
    [self cleanup];
}

- (void)cleanup {
    SYNCHRONIZED_BEGIN(filledBuffersLock);
    
    activeAudioPlayers.erase(_playerId);
    
    for (int i = 0; i < OpusAudioPlayerBufferCount; i++)
    {
        if (_filledAudioBuffers[i] != NULL)
        {
            OpusAudioBufferDispose(_filledAudioBuffers[i]);
            _filledAudioBuffers[i] = NULL;
        }
    }
    _filledAudioBufferCount = 0;
    _filledAudioBufferPosition = 0;
    
    SYNCHRONIZED_END(filledBuffersLock);
    
    OggOpusFile *opusFile = _opusFile;
    _opusFile = NULL;
    
    AudioUnit audioUnit = _audioUnit;
    _audioUnit = NULL;
    
    intptr_t objectId = (intptr_t)self;
    
    [queue dispatch:^{
         if (audioUnit != NULL)
         {
             OSStatus status = noErr;
             status = AudioOutputUnitStop(audioUnit);
             if (status != noErr)
                 NSLog(@"[OpusAudioPlayer#%lx AudioOutputUnitStop failed: %d]", objectId, (int)status);
             
             status = AudioComponentInstanceDispose(audioUnit);
             if (status != noErr)
                 NSLog(@"[OpusAudioRecorder#%lx AudioComponentInstanceDispose failed: %d]", objectId, (int)status);
         }
         
         if (opusFile != NULL)
             op_free(opusFile);
     }];
    
}

static OSStatus OpusAudioPlayerCallback(void *inRefCon, __unused AudioUnitRenderActionFlags *ioActionFlags, __unused const AudioTimeStamp *inTimeStamp, __unused UInt32 inBusNumber, __unused UInt32 inNumberFrames, AudioBufferList *ioData) {
    int playerId = (int)(NSInteger)inRefCon;
    
    SYNCHRONIZED_BEGIN(filledBuffersLock);
    
    OpusPlayer *self = nil;
    auto it = activeAudioPlayers.find(playerId);
    if (it != activeAudioPlayers.end())
        self = it->second;
    
    if (self != nil)
    {
        OpusAudioBuffer **freedAudioBuffers = NULL;
        int freedAudioBufferCount = 0;
        
        for (int i = 0; i < (int)ioData->mNumberBuffers; i++)
        {
            AudioBuffer *buffer = &ioData->mBuffers[i];
            
            buffer->mNumberChannels = 1;
            
            int requiredBytes = buffer->mDataByteSize;
            int writtenBytes = 0;
            
            while (self->_filledAudioBufferCount > 0 && writtenBytes < requiredBytes)
            {
                os_unfair_lock_lock(&audioPositionLock);
                self->_currentPcmOffset = self->_filledAudioBuffers[0]->pcmOffset + self->_filledAudioBufferPosition / 2;
                os_unfair_lock_unlock(&audioPositionLock);
                
                int takenBytes = MIN((int)self->_filledAudioBuffers[0]->size - self->_filledAudioBufferPosition, requiredBytes - writtenBytes);
                
                if (takenBytes != 0)
                {
                    memcpy(((uint8_t *)buffer->mData) + writtenBytes, self->_filledAudioBuffers[0]->data + self->_filledAudioBufferPosition, takenBytes);
                    writtenBytes += takenBytes;
                }
                
                if (self->_filledAudioBufferPosition + takenBytes >= (int)self->_filledAudioBuffers[0]->size)
                {
                    if (freedAudioBuffers == NULL)
                        freedAudioBuffers = (OpusAudioBuffer **)malloc(sizeof(OpusAudioBuffer *) * OpusAudioPlayerBufferCount);
                    freedAudioBuffers[freedAudioBufferCount] = self->_filledAudioBuffers[0];
                    freedAudioBufferCount++;
                    
                    for (int i = 0; i < OpusAudioPlayerBufferCount - 1; i++)
                    {
                        self->_filledAudioBuffers[i] = self->_filledAudioBuffers[i + 1];
                    }
                    self->_filledAudioBuffers[OpusAudioPlayerBufferCount - 1] = NULL;
                    
                    self->_filledAudioBufferCount--;
                    self->_filledAudioBufferPosition = 0;
                }
                else
                    self->_filledAudioBufferPosition += takenBytes;
            }
            
            if (writtenBytes < requiredBytes)
                memset(((uint8_t *)buffer->mData) + writtenBytes, 0, requiredBytes - writtenBytes);
        }
        
        if (freedAudioBufferCount != 0)
        {
            [queue dispatch:^{
                 for (int i = 0; i < freedAudioBufferCount; i++)
                 {
                     [self fillBuffer:freedAudioBuffers[i]];
                 }
                 
                 free(freedAudioBuffers);
             }];
        }
    } else {
        for (int i = 0; i < (int)ioData->mNumberBuffers; i++)
        {
            AudioBuffer *buffer = &ioData->mBuffers[i];
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }
    
    SYNCHRONIZED_END(filledBuffersLock);
    
    return noErr;
}

- (void)play {
    [self playFromPosition:[self currentPositionSync:true]];
}

- (void)playFromPosition:(NSTimeInterval)position {
    [queue dispatch:^{
        if (!self->_isPaused)
             return;
         
        if (self->_audioUnit == NULL)
         {
             
             self->_isPaused = false;
             
             int openError = OPUS_OK;
             self->_opusFile = op_open_file([self->_filePath UTF8String], &openError);
             if (self->_opusFile == NULL || openError != OPUS_OK)
             {
                 NSLog(@"[OpusAudioPlayer#%p op_open_file failed: %d]", self, openError);
                 [self cleanupAndReportError];
                 
                 return;
             }
             
             self->_isSeekable = op_seekable(self->_opusFile);
             self->_totalPcmDuration = op_pcm_total(self->_opusFile, -1);
             
             AudioComponentDescription desc;
             desc.componentType = kAudioUnitType_Output;
             desc.componentSubType = kAudioUnitSubType_RemoteIO;
             desc.componentFlags = 0;
             desc.componentFlagsMask = 0;
             desc.componentManufacturer = kAudioUnitManufacturer_Apple;
             AudioComponent inputComponent = AudioComponentFindNext(NULL, &desc);
             AudioComponentInstanceNew(inputComponent, &self->_audioUnit);
             
             OSStatus status = noErr;
             
             static const UInt32 one = 1;
             status = AudioUnitSetProperty(self->_audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, kOutputBus, &one, sizeof(one));
             if (status != noErr)
             {
                 NSLog(@"[OpusAudioPlayer#%@ AudioUnitSetProperty kAudioOutputUnitProperty_EnableIO failed: %d]", self, (int)status);
                 [self cleanupAndReportError];
                 
                 return;
             }
             
             AudioStreamBasicDescription outputAudioFormat;
             outputAudioFormat.mSampleRate = OpusAudioPlayerSampleRate;
             outputAudioFormat.mFormatID = kAudioFormatLinearPCM;
             outputAudioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
             outputAudioFormat.mFramesPerPacket = 1;
             outputAudioFormat.mChannelsPerFrame = 1;
             outputAudioFormat.mBitsPerChannel = 16;
             outputAudioFormat.mBytesPerPacket = 2;
             outputAudioFormat.mBytesPerFrame = 2;
             status = AudioUnitSetProperty(self->_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kOutputBus, &outputAudioFormat, sizeof(outputAudioFormat));
             if (status != noErr)
             {
                 NSLog(@"[OpusAudioPlayer#%@ AudioUnitSetProperty kAudioUnitProperty_StreamFormat failed: %d]", self, (int)status);
                 [self cleanupAndReportError];
                 
                 return;
             }
             
             AURenderCallbackStruct callbackStruct;
             callbackStruct.inputProc = &OpusAudioPlayerCallback;
             callbackStruct.inputProcRefCon = (void *)(NSInteger)self->_playerId;
             if (AudioUnitSetProperty(self->_audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, kOutputBus, &callbackStruct, sizeof(callbackStruct)) != noErr)
             {
                 NSLog(@"[OpusAudioPlayer#%@ AudioUnitSetProperty kAudioUnitProperty_SetRenderCallback failed]", self);
                 [self cleanupAndReportError];
                 
                 return;
             }
             
             status = AudioUnitInitialize(self->_audioUnit);
             if (status != noErr)
             {
                 NSLog(@"[OpusAudioRecorder#%@ AudioUnitInitialize failed: %d]", self, (int)status);
                 [self cleanup];
                 
                 return;
             }
             
             SYNCHRONIZED_BEGIN(filledBuffersLock);
             activeAudioPlayers[self->_playerId] = self;
             SYNCHRONIZED_END(filledBuffersLock);
             
             NSUInteger bufferByteSize = [self bufferByteSize];
             for (int i = 0; i < OpusAudioPlayerBufferCount; i++)
             {
                 self->_filledAudioBuffers[i] = OpusAudioBufferWithCapacity(bufferByteSize);
             }
             self->_filledAudioBufferCount = OpusAudioPlayerBufferCount;
             self->_filledAudioBufferPosition = 0;
             
             self->_finished = false;
             
             if (self->_isSeekable && position >= 0.0)
                 op_pcm_seek(self->_opusFile, (ogg_int64_t)(position * OpusAudioPlayerSampleRate));
             
             status = AudioOutputUnitStart(self->_audioUnit);
             if (status != noErr)
             {
                 NSLog(@"[OpusAudioRecorder#%@ AudioOutputUnitStart failed: %d]", self, (int)status);
                 [self cleanupAndReportError];
             }
             
         }
         else
         {
             
             if (self->_isSeekable && position >= 0.0)
             {
                 int result = op_pcm_seek(self->_opusFile, (ogg_int64_t)(position * OpusAudioPlayerSampleRate));
                 if (result != OPUS_OK)
                     NSLog(@"[OpusAudioPlayer#%p op_pcm_seek failed: %d]", self, result);
                 
                 ogg_int64_t pcmPosition = op_pcm_tell(self->_opusFile);
                 self->_currentPcmOffset = pcmPosition;
                 
                 self->_isPaused = false;
             }
             else
                 self->_isPaused = false;
             
             self->_finished = false;
             
             SYNCHRONIZED_BEGIN(filledBuffersLock);
             for (int i = 0; i < self->_filledAudioBufferCount; i++)
             {
                 self->_filledAudioBuffers[i]->size = 0;
             }
             self->_filledAudioBufferPosition = 0;
             SYNCHRONIZED_END(filledBuffersLock);
         }
         [self _notifyStart];
       
     }];
}

- (void)fillBuffer:(OpusAudioBuffer *)audioBuffer {
    if (_opusFile != NULL)
    {
        audioBuffer->pcmOffset = MAX(0, op_pcm_tell(_opusFile));
        
        if (!_isPaused)
        {
            if (_finished)
            {
                bool notifyFinished = false;
                SYNCHRONIZED_BEGIN(filledBuffersLock);
                if (_filledAudioBufferCount == 0)
                    notifyFinished = true;
                SYNCHRONIZED_END(filledBuffersLock);
                
                if (notifyFinished)
                    [self _notifyFinished];
                
                return;
            }
            else
            {
                int availableOutputBytes = (int)audioBuffer->capacity;
                int writtenOutputBytes = 0;
                
                bool endOfFileReached = false;
                
                bool bufferPcmOffsetSet = false;
                
                while (writtenOutputBytes < availableOutputBytes)
                {
                    if (!bufferPcmOffsetSet)
                    {
                        bufferPcmOffsetSet = true;
                        audioBuffer->pcmOffset = MAX(0, op_pcm_tell(_opusFile));
                    }
                    
                    int readSamples = op_read(_opusFile, (opus_int16 *)(audioBuffer->data + writtenOutputBytes), (availableOutputBytes - writtenOutputBytes) / 2, NULL);
                    
                    if (readSamples > 0)
                        writtenOutputBytes += readSamples * 2;
                    else
                    {
                        if (readSamples < 0)
                            NSLog(@"[OpusAudioPlayer#%p op_read failed: %d]", self, readSamples);
                        
                        endOfFileReached = true;
                        
                        break;
                    }
                }
                
                audioBuffer->size = writtenOutputBytes;
                
                if (endOfFileReached)
                    _finished = true;
            }
        }
        else
        {
            memset(audioBuffer->data, 0, audioBuffer->capacity);
            audioBuffer->size = audioBuffer->capacity;
            audioBuffer->pcmOffset = _currentPcmOffset;
        }
    }
    else
    {
        memset(audioBuffer->data, 0, audioBuffer->capacity);
        audioBuffer->size = audioBuffer->capacity;
        audioBuffer->pcmOffset = _totalPcmDuration;
    }
    
    SYNCHRONIZED_BEGIN(filledBuffersLock);
    _filledAudioBufferCount++;
    _filledAudioBuffers[_filledAudioBufferCount - 1] = audioBuffer;
    SYNCHRONIZED_END(filledBuffersLock);
}

- (NSUInteger)bufferByteSize
{
    static const NSUInteger maxBufferSize = 0x50000;
    static const NSUInteger minBufferSize = 0x4000;
    
    Float64 seconds = 0.4;
    
    Float64 numPacketsForTime = OpusAudioPlayerSampleRate * seconds;
    NSUInteger result = (NSUInteger)(numPacketsForTime * 2);
    
    return MAX(minBufferSize, MIN(maxBufferSize, result));
}

- (void)pause {
    [self pause:true];
}

- (void)pause:(bool)notify {
    [queue dispatch:^{
        self->_isPaused = true;
         
         SYNCHRONIZED_BEGIN(filledBuffersLock);
        for (int i = 0; i < self->_filledAudioBufferCount; i++)
         {
             if (self->_filledAudioBuffers[i]->size != 0)
                 memset(self->_filledAudioBuffers[i]->data, 0, self->_filledAudioBuffers[i]->size);
             self->_filledAudioBuffers[i]->pcmOffset = self->_currentPcmOffset;
         }
         SYNCHRONIZED_END(filledBuffersLock);
     }];
    if (notify)
        [self _notifyPause];
}

- (void)stop
{
    [queue dispatch:^{
         [self cleanup];
     }];
    
}

- (NSTimeInterval)currentPositionSync:(bool)sync {
    __block NSTimeInterval result = 0.0;
    
    dispatch_block_t block = ^
    {
        os_unfair_lock_lock(&audioPositionLock);
        result = (float)self->_currentPcmOffset / (float)OpusAudioPlayerSampleRate;
        os_unfair_lock_unlock(&audioPositionLock);
    };
    
    if (sync)
        [queue dispatch:block synchronous:true];
    else
        block();
    
    return result;
}

-(void)setCurrentPosition:(NSTimeInterval)position {
    [queue dispatch:^{
        if (self->_isPaused) {
            [self playFromPosition:position];
            [self pause];
        } else {
            [self pause:false];
            [self playFromPosition:position];
        }
    }];
}

- (NSTimeInterval)duration {
    return _totalPcmDuration / (NSTimeInterval)OpusAudioPlayerSampleRate;
}


- (void)_notifyFinished {
    id<OpusPlayerDelegate> delegate = _delegate;
    if ([delegate respondsToSelector:@selector(audioPlayerDidFinishPlaying:)])
        [delegate audioPlayerDidFinishPlaying:self];
}

- (void)_notifyStart {
    id<OpusPlayerDelegate> delegate = _delegate;
    if ([delegate respondsToSelector:@selector(audioPlayerDidStartPlaying:)])
        [delegate audioPlayerDidStartPlaying:self];
}

- (void)_notifyPause {
    id<OpusPlayerDelegate> delegate = _delegate;
    if ([delegate respondsToSelector:@selector(audioPlayerDidPause:)])
        [delegate audioPlayerDidPause:self];
}

@end
