//
//  ViewController.m
//  H264EncodeDemo
//
//  Created by WangJie on 2017/12/19.
//  Copyright © 2017年 WangJie. All rights reserved.
//

#import "ViewController.h"
#import <VideoToolbox/VideoToolbox.h>
#import <AVFoundation/AVFoundation.h>
#include "libyuv.h"

#define SCREEN_WIDTH    [UIScreen mainScreen].bounds.size.width
#define SCREEN_HEIGHT   [UIScreen mainScreen].bounds.size.height

@interface ViewController () <AVCaptureVideoDataOutputSampleBufferDelegate>
{
    VTCompressionSessionRef _encodeSession;
    dispatch_queue_t _encodeQueue;
    long _frameCount;
    FILE *_h264File;
    int _spsppsFound;
    
    FILE *_rgbFile;
    FILE *_yuvFile;
    
    uint8_t* _outbuffer;
    uint8_t* _outbuffer_tmp;
}
@property (nonatomic, strong) NSString *documentDictionary;
@property (nonatomic, strong) AVCaptureSession *videoCaptureSession;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
//    [self initVideoCapture];
    
    _encodeQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    int numBytes = 640*480*3/2;
    _outbuffer = (uint8_t*)malloc(numBytes*sizeof(uint8_t));
    numBytes = 640*480*4;
    _outbuffer_tmp = (uint8_t*)malloc(numBytes*sizeof(uint8_t));
    
    self.documentDictionary = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    
    UIButton *startBtn = [[UIButton alloc] initWithFrame:CGRectMake(10, SCREEN_HEIGHT-50, 80, 50)];
    [startBtn setTitle:@"START" forState:UIControlStateNormal];
    [startBtn setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [startBtn addTarget:self action:@selector(start) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:startBtn];
    
    UIButton *stopBtn = [[UIButton alloc] initWithFrame:CGRectMake(SCREEN_WIDTH-90, SCREEN_HEIGHT-50, 80, 50)];
    [stopBtn setTitle:@"STOP" forState:UIControlStateNormal];
    [stopBtn setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [stopBtn addTarget:self action:@selector(stop) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:stopBtn];
}

- (void)initVideoCapture {
    self.videoCaptureSession = [[AVCaptureSession alloc] init];
    [self.videoCaptureSession setSessionPreset:AVCaptureSessionPreset640x480];
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (!device) {
        NSLog(@"no video device found");
        return;
    }
    AVCaptureDeviceInput *inputDevice = [AVCaptureDeviceInput deviceInputWithDevice:device error:nil];
    if ([self.videoCaptureSession canAddInput:inputDevice]) {
        NSLog(@"add video input to video session: %@", inputDevice);
        [self.videoCaptureSession addInput:inputDevice];
    }
    AVCaptureVideoDataOutput *dataOutput = [[AVCaptureVideoDataOutput alloc] init];
    // only support pixel format: 420v 420f bgra
    dataOutput.videoSettings = [NSDictionary dictionaryWithObject:
                                [NSNumber numberWithUnsignedInt:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] forKey:(NSString *)kCVPixelBufferPixelFormatTypeKey];
    [dataOutput setAlwaysDiscardsLateVideoFrames:YES];
    if ([self.videoCaptureSession canAddOutput:dataOutput]) {
        NSLog(@"add video output to video session: %@", dataOutput);
        [self.videoCaptureSession addOutput:dataOutput];
    }
    // 设置采集图像的方向，如果不设置，采集回来的图形会是旋转90度的
    AVCaptureConnection *connection = [dataOutput connectionWithMediaType:AVMediaTypeVideo];
    connection.videoOrientation = AVCaptureVideoOrientationPortrait;
    [self.videoCaptureSession commitConfiguration];
    
    // 添加预览
    CGRect frame = self.view.frame;
    frame.size.height -= 50;
    AVCaptureVideoPreviewLayer *previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:self.videoCaptureSession];
    [previewLayer setVideoGravity:AVLayerVideoGravityResizeAspectFill];
    [previewLayer setFrame:frame];
    [self.view.layer addSublayer:previewLayer];
    // 摄像头采集queue
    dispatch_queue_t queue = dispatch_queue_create("VideoCaptureQueue", DISPATCH_QUEUE_SERIAL);
    [dataOutput setSampleBufferDelegate:self queue:queue];
}

- (void)start {
    _h264File = fopen([[NSString stringWithFormat:@"%@/vt_encode.h264", self.documentDictionary] UTF8String], "wb");
    _yuvFile = fopen([[NSString stringWithFormat:@"%@/vt.yuv", self.documentDictionary] UTF8String], "wb");
    _rgbFile = fopen([[NSString stringWithFormat:@"%@/vt.rgb", self.documentDictionary] UTF8String], "wb");

}

- (int)startEncodeSession:(int)width height:(int)height framerate:(int)fps bitrate:(int)bt {
    OSStatus status;
    _frameCount = 0;
    VTCompressionOutputCallback cb = encodeOutputCallback;
    status = VTCompressionSessionCreate(kCFAllocatorDefault, width, height, kCMVideoCodecType_H264, NULL, NULL, NULL, cb, (__bridge void*)(self), &_encodeSession);
    if (status != noErr) {
        NSLog(@"VTCompressionSessionCreate failed. ret = %d", (int)status);
        return -1;
    }
    // 设置实时编码输出，降低编码延迟
    status = VTSessionSetProperty(_encodeSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    NSLog(@"set realtime return: %d", (int)status);
    // h264 profile, 直播一般使用baseline， 可减少由于b帧带来的延时
    status = VTSessionSetProperty(_encodeSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
    NSLog(@"set profile return: %d", (int)status);
    // 设置编码码率-比特率，如果不设置，默认将会以很低的码率编码，视频会很模糊
    status  = VTSessionSetProperty(_encodeSession, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(bt)); // bps
   status += VTSessionSetProperty(_encodeSession, kVTCompressionPropertyKey_DataRateLimits, (__bridge CFArrayRef)@[@(bt*2/8), @1]); // Bps
    NSLog(@"set bitrate return: %d", (int)status);
    
    // 设置关键帧间隔，gap size
    status = VTSessionSetProperty(_encodeSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(fps*2));
    // 设置帧率，只用于初始化session，不是实际fps
    status = VTSessionSetProperty(_encodeSession, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef)@(fps));
    NSLog(@"set framerate return: %d", (int)status);
    // 开始编码
    status = VTCompressionSessionPrepareToEncodeFrames(_encodeSession);
    NSLog(@"start encode return: %d", (int)status);
    return 0;
}

// 编码回掉，每当系统编码完一帧会异步调用该方法
void encodeOutputCallback(void *userData, void *sourceFrameRefCon, OSStatus status, VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer)
{
    if (status != noErr)
    {
        NSLog(@"didCompressH264 error: with status %d, infoFlags %d", (int)status, (int)infoFlags);
        return;
    }
    if (!CMSampleBufferDataIsReady(sampleBuffer))
    {
        NSLog(@"didCompressH264 data is not ready");
        return;
    }
    ViewController *vc = (__bridge ViewController*)userData;
    // 判断当前帧是否为关键帧
    bool keyframe = !CFDictionaryContainsKey( (CFArrayGetValueAtIndex(CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true), 0)), kCMSampleAttachmentKey_NotSync);
    if (keyframe && !vc->_spsppsFound)
    {
        size_t spsSize, spsCount;
        size_t ppsSize, ppsCount;
        const uint8_t *spsData, *ppsData;
        CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
        OSStatus err0 = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, 0, &spsData, &spsSize, &spsCount, 0 );
        OSStatus err1 = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, 1, &ppsData, &ppsSize, &ppsCount, 0 );
        if (err0==noErr && err1==noErr)
        {
            vc->_spsppsFound = 1;
            [vc writeH264Data:(void *)spsData length:spsSize addStartCode:YES];
            [vc writeH264Data:(void *)ppsData length:ppsSize addStartCode:YES];
            
            NSLog(@"got sps/pps data. Length: sps=%zu, pps=%zu", spsSize, ppsSize);
        }
    }
    size_t lengthAtOffset, totalLength;
    char *data;
    CMBlockBufferRef dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    OSStatus error = CMBlockBufferGetDataPointer(dataBuffer, 0, &lengthAtOffset, &totalLength, &data);
    if (error == noErr) {
        size_t offset = 0;
        const int lengthInfoSize = 4;
        while (offset < totalLength - lengthInfoSize) {
            uint32_t naluLength = 0;
            memcpy(&naluLength, data + offset, lengthInfoSize);
            naluLength = CFSwapInt32BigToHost(naluLength);
            NSLog(@"got nalu data, length = %d, totalLength = %zu", naluLength, totalLength);
            [vc writeH264Data:data+offset+lengthInfoSize length:naluLength addStartCode:YES];
            offset += lengthInfoSize+naluLength;
        }
    }
}

- (void)writeH264Data:(void*)data length:(size_t)length addStartCode:(BOOL)b {
    const Byte bytes[] = "\x00\x00\x00\x01";
    if (_h264File) {
        if (b) {
            fwrite(bytes, 1, 4, _h264File);
        }
        fwrite(data, 1, length, _h264File);
    } else {
        NSLog(@"_h264File null error, check if it open successed");
    }
}

- (void)stop {
    [self.videoCaptureSession stopRunning];
    [self stopEncodeSession];
    fclose(_h264File);
    fclose(_yuvFile);
    fclose(_rgbFile);
}

- (void)stopEncodeSession {
    VTCompressionSessionCompleteFrames(_encodeSession, kCMTimeInvalid);
    VTCompressionSessionInvalidate(_encodeSession);
    CFRelease(_encodeSession);
    _encodeSession = NULL;
}

#pragma mark -
- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    UIImage *image = [UIImage imageNamed:@"480.jpg"];
    CGImageRef newCGImage = [image CGImage];
    CGDataProviderRef dataProvider = CGImageGetDataProvider(newCGImage);
    CFDataRef bitmapData = CGDataProviderCopyData(dataProvider);
    _outbuffer = (uint8_t *)CFDataGetBytePtr(bitmapData);
    fwrite(_outbuffer, 1, 480*640*4, _rgbFile);
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault,
                                          480, 640,
                                          kCVPixelFormatType_420YpCbCr8Planar ,
                                          NULL,
                                          &pixelBuffer);
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    uint8_t *yDestPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    uint8_t *uDestPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
    uint8_t *vDestPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 2);
    if (result != kCVReturnSuccess) {
        NSLog(@"unable to create cvpixelbuffer %d", result);
    }
    
    // cnvert color space 颜色空间转换
    int frame_width = 480;
    ConvertToI420((uint8_t *)_outbuffer , 640 * 480,
                  yDestPlane, frame_width,
                  uDestPlane , frame_width /2 ,
                  vDestPlane, frame_width /2 ,
                  0, 0,
                  480 ,640 ,//src_width, src_height,
                  480 ,640,
                  0, FOURCC_ABGR);  // 上面从uiimage中获取的颜色空间格式 RGBA ,但是这里用的是FOURCC_ABGR ，这里应该是大小端的问题
    
    fwrite(yDestPlane, 1, 480*640, _yuvFile);
    fwrite(uDestPlane, 1, 480*640/4, _yuvFile);
    fwrite(vDestPlane, 1, 480*640/4, _yuvFile);
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    CMSampleBufferRef newSampleBuffer = NULL;
    CMSampleTimingInfo timimgInfo = kCMTimingInfoInvalid;
    CMVideoFormatDescriptionRef videoInfo = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixelBuffer, &videoInfo);
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, NULL, NULL, videoInfo, &timimgInfo, &newSampleBuffer);
    [self encodeFrame:newSampleBuffer];
    CVPixelBufferRelease(pixelBuffer);
    CFRelease(bitmapData);
}

- (void)encodeFrame:(CMSampleBufferRef)sampleBuffer {
    dispatch_sync(_encodeQueue, ^{
        CVImageBufferRef imageBuffer = (CVImageBufferRef)CMSampleBufferGetImageBuffer(sampleBuffer);
        CMTime pts = CMTimeMake(_frameCount, 1000);
        CMTime duration = kCMTimeInvalid;
        VTEncodeInfoFlags flags;
        OSStatus statusCode = VTCompressionSessionEncodeFrame(_encodeSession, imageBuffer, pts, duration, NULL
                                                              , NULL, &flags);
        if (statusCode != noErr) {
            [self stopEncodeSession];
            return ;
        }
    });
}

@end
