//
//  ViewController.m
//  FFmpegDemo
//
//  Created by luxu on 2022/2/8.
//

#import "ViewController.h"

//extern "C" {
    #import "libavformat/avformat.h"
    #import "libswscale/swscale.h"
    #import "libswresample/swresample.h"
    #import "libavutil/pixdesc.h"
    #import "libavutil/imgutils.h"
//}

@interface ViewController ()

@end


@implementation ViewController

int interrupt_callback(void *param) {
    return 0;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor redColor];
    // Do any additional setup after loading the view.
    
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self videoDecoder];
}

/// 解码 解码为音频、视频原始数据 pcm、yuv
- (void)videoDecoder {
    // 注册
    avformat_network_init();
//    av_register_all();
    
    // 打开文件，设置回调
    AVFormatContext *formatContext = avformat_alloc_context();
    AVIOInterruptCB int_cb = {interrupt_callback, (__bridge void *)(self)};
    formatContext->interrupt_callback = int_cb;
    const char *videoPath = [[NSBundle mainBundle] pathForResource:@"video1" ofType:@"MP4"].UTF8String;
    avformat_open_input(&formatContext, videoPath, NULL, NULL);
    avformat_find_stream_info(formatContext, NULL);

    // 获取流
    AVStream *videoStream = NULL;
    AVStream *audioStream = NULL;
    for (int i = 0 ; i < formatContext->nb_streams; i++) {
        AVStream *stream = formatContext->streams[i];
        if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            videoStream = stream;
        } else if (stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            audioStream = stream;
        }
    }
    int videoStreamIndex = videoStream->index;
    int audioStreamIndex = audioStream->index;
    
    // 音频解码器
    AVCodecParameters *audioCodecpar = audioStream->codecpar;
    AVCodec *audioCodec = avcodec_find_decoder(audioCodecpar->codec_id);
    if (audioCodec == NULL) {
        NSLog(@"找不到音频解码器");
        return;
    }
    AVCodecContext *audioCodecContext = avcodec_alloc_context3(audioCodec);
    avcodec_parameters_to_context(audioCodecContext, audioCodecpar);
    int audioCodecRet = avcodec_open2(audioCodecContext, audioCodec, NULL);
    if (audioCodecRet != 0) {
        NSLog(@"音频解码器打开失败");
        return;
    }
    
    // 视频解码器
    AVCodecParameters *videoCodecpar = videoStream->codecpar;
    AVCodec *videoCodec = avcodec_find_decoder(videoCodecpar->codec_id);
    if (videoCodec == NULL) {
        NSLog(@"找不到视频解码器");
        return;
    }
    AVCodecContext *videoCodecContext = avcodec_alloc_context3(videoCodec);
    avcodec_parameters_to_context(videoCodecContext, videoCodecpar);
    int videoCodecRet = avcodec_open2(videoCodecContext, videoCodec, NULL);
    if (videoCodecRet != 0) {
        NSLog(@"视频解码器打开失败");
        return;
    }
    
    // 音频重采样
    SwrContext *swrcontext = NULL;
    if (audioCodecContext->sample_fmt != AV_SAMPLE_FMT_S16) {
        swrcontext = swr_alloc_set_opts(NULL, AV_CH_LAYOUT_STEREO, AV_SAMPLE_FMT_S16, 44100, audioCodecContext->channel_layout, audioCodecContext->sample_fmt, audioCodecContext->sample_rate, 0, NULL);
        if (!swrcontext || swr_init(swrcontext)) {
            if (swrcontext) {
                swr_free(&swrcontext);
            }
        }
    }

    // 视频像素格式
    struct SwsContext *swscontext = NULL;
    uint8_t* imageData[4];
    int linesize[4];
    int imageSize = av_image_alloc(imageData, linesize, videoCodecContext->width, videoCodecContext->height, AV_PIX_FMT_YUV420P, 1);
    if (!imageSize) {
        NSLog(@"image alloc faild");
        return;
    }
    swscontext = sws_getCachedContext(swscontext, videoCodecContext->width, videoCodecContext->height, videoCodecContext->pix_fmt, videoCodecContext->width, videoCodecContext->height, AV_PIX_FMT_YUV420P, SWS_FAST_BILINEAR, NULL, NULL, NULL);
    
    // 解码
    NSString *outPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *videoOutPath = [outPath stringByAppendingString:@"/video.yuv"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:videoOutPath]) {
        [[NSFileManager defaultManager] removeItemAtPath:videoOutPath error:nil];
    }
    [[NSFileManager defaultManager] createFileAtPath:videoOutPath contents:nil attributes:nil];
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:videoOutPath];
    [fileHandle seekToEndOfFile];
    NSMutableData *audioData = [NSMutableData data];
    uint8_t *audioBuffer = (uint8_t *)av_malloc(2 * 44100);
    AVFrame *audioFrame = av_frame_alloc();
    AVFrame *videoFrame = av_frame_alloc();
    AVPacket packet;
    while (av_read_frame(formatContext, &packet) == 0) {
        int packetIndex = packet.stream_index;
        if (packetIndex == audioStreamIndex) {
            // 压缩数据
            avcodec_send_packet(audioCodecContext, &packet);
            // 原始数据
            avcodec_receive_frame(audioCodecContext, audioFrame);
            
            int audioSamples = audioFrame->nb_samples;
//            int fmt = audioFrame->format;
//            int cn = audioFrame->channels;
            
            if (!swrcontext) {
                audioBuffer = audioFrame->data[0];
            } else {
                swr_convert(swrcontext, &audioBuffer, 2 * 44100,
                            (const uint8_t **)audioFrame->data, audioSamples);
            }
            int size = av_samples_get_buffer_size(NULL, 2, audioSamples, AV_SAMPLE_FMT_S16, 1);
            if (size > 0) {
                [audioData appendData:[NSData dataWithBytes:audioBuffer length:size]];
            }
        } else if (packetIndex == videoStreamIndex) {
            avcodec_send_packet(videoCodecContext, &packet);
            avcodec_receive_frame(videoCodecContext, videoFrame);
            
            uint8_t* luma;
            uint8_t* chromaB;
            uint8_t* chromaR;
//            if (videoCodecContext->pix_fmt == AV_PIX_FMT_YUV420P || videoCodecContext->pix_fmt == AV_PIX_FMT_YUVJ420P) {
//                luma = videoFrame->data[0];
//                chromaB = videoFrame->data[1];
//                chromaR = videoFrame->data[2];
//            } else {
                sws_scale(swscontext, (const uint8_t **)videoFrame->data, videoFrame->linesize, 0, videoCodecContext->height, imageData, linesize);
                luma = imageData[0];
                chromaB = imageData[1];
                chromaR = imageData[2];
//            }
            int imageSize = videoCodecContext->width * videoCodecContext->height;
            if (luma) {
                [fileHandle writeData:[NSData dataWithBytes:luma length:imageSize]];
            }
            if (chromaB) {
                [fileHandle writeData:[NSData dataWithBytes:chromaB length:imageSize/4]];
            }
            if (chromaR) {
                [fileHandle writeData:[NSData dataWithBytes:chromaR length:imageSize/4]];
            }
        }
    }
    
    // 保存解码后的数据
    [fileHandle closeFile];
    // ffplay -s 720x1280 -pix_fmt yuv420p -i video.yuv
    
    [audioData writeToFile:[outPath stringByAppendingString:@"/audio.pcm"] options:NSDataWritingAtomic error:nil];
    // ffplay -ar 44100 -ac 2 -f s16le -i audio.pcm
    

    // 关闭音频资源
    if (swrcontext) {
        swr_free(&swrcontext);
        swrcontext = NULL;
    }
    if (audioFrame) {
        av_free(audioFrame);
        audioFrame = NULL;
    }
    if (audioCodecContext) {
        avcodec_close(audioCodecContext);
        audioCodecContext = NULL;
    }
    // 关闭视频资源
    if (swscontext) {
        sws_freeContext(swscontext);
        swscontext = NULL;
    }
    if (videoFrame) {
        av_free(videoFrame);
        videoFrame = NULL;
    }
    if (videoCodecContext) {
        avcodec_close(videoCodecContext);
        videoCodecContext = NULL;
    }
    // 关闭文件资源
    if (formatContext) {
        avformat_close_input(&formatContext);
        formatContext = NULL;
    }
}

@end
