#ifndef Runner_Bridging_Header_h
#define Runner_Bridging_Header_h

// Ogg Opus 编解码直接调 libopus/libogg。这两个库是静态链接的（macos/Vendor），
// 不依赖 Apple 的容器支持，也不引入运行时 dylib。
#import <opus/opus.h>
#import <ogg/ogg.h>

#endif
