#import "ViewController.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

@interface ViewController ()
@property (nonatomic) CFSocketRef socket;
@end

@implementation ViewController

id<MTLDevice> device;
NSMutableDictionary<NSString *, id> *objects;
NSMutableDictionary<NSString *, id> *buffers;
NSMutableArray<id<MTLCommandBuffer>> *mtl_buffers_in_flight;
id<MTLCommandQueue> mtl_queue;

- (void)viewDidLoad {
    objects = [[NSMutableDictionary alloc] init];
    buffers = [[NSMutableDictionary alloc] init];
    device = MTLCreateSystemDefaultDevice();
    mtl_queue = [device newCommandQueueWithMaxCommandBufferCount:1024];
    mtl_buffers_in_flight = [[NSMutableArray alloc] init];
    [super viewDidLoad];
    [self startHTTPServer];
}


- (void)startHTTPServer {
    self.socket = CFSocketCreate(NULL, PF_INET, SOCK_STREAM, IPPROTO_TCP, kCFSocketAcceptCallBack, AcceptCallback, NULL);
    if (!self.socket) {
        NSLog(@"Unable to create socket.");
        return;
    }
    
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(6667);  //use same port on tinygrad
    address.sin_addr.s_addr = INADDR_ANY;
    
    CFDataRef addressData = CFDataCreate(NULL, (const UInt8 *)&address, sizeof(address));
    if (CFSocketSetAddress(self.socket, addressData) != kCFSocketSuccess) {
        NSLog(@"Failed to bind socket to address.");
        CFRelease(self.socket);
        self.socket = NULL;
        exit(0); //TODO, add ui or retry
        return;
    }
    CFRelease(addressData);
    
    CFRunLoopSourceRef source = CFSocketCreateRunLoopSource(NULL, self.socket, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
    CFRelease(source);
    
    NSLog(@"HTTP Server started on port 6667.");
}

NSArray<NSString *> *extractValues(NSString *pattern, NSString *x) {
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSRange range = [[regex firstMatchInString:x options:0 range:NSMakeRange(0, x.length)] rangeAtIndex:1];
    NSString *contents = [x substringWithRange:range];
    NSArray<NSString *> *rawValues = [contents componentsSeparatedByString:@","];
    NSMutableArray<NSString *> *values = [NSMutableArray array];

    for (NSString *value in rawValues) {
        NSString *trimmedValue = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmedValue.length > 0) {
            [values addObject:trimmedValue];
        }
    }
    return [values copy];
}

static void AcceptCallback(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address, const void *data, void *info) {
    CFSocketNativeHandle handle = *(CFSocketNativeHandle *)data;
    char buffer[1024 * 500] = {0};
    struct timeval timeout;
    timeout.tv_sec = 1;
    timeout.tv_usec = 0;
    setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, (const char *)&timeout, sizeof(timeout));
    ssize_t bytes = recv(handle, buffer, sizeof(buffer) - 1, 0);
    buffer[bytes] = '\0';
    CFDataRef dataRef = CFDataCreate(NULL, (UInt8 *)buffer, (CFIndex)bytes);
    CFHTTPMessageRef httpRequest = CFHTTPMessageCreateEmpty(NULL, TRUE);
    CFHTTPMessageAppendBytes(httpRequest, CFDataGetBytePtr(dataRef), CFDataGetLength(dataRef));
    NSString *requestPath = [(__bridge_transfer NSURL *)CFHTTPMessageCopyRequestURL(httpRequest) path];
    if ([requestPath hasPrefix:@"/renderer"]) {
        char *response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n[\"tinygrad.renderer.cstyle\", \"MetalRenderer\", []]";
        send(handle, response, strlen(response), 0);
        close(handle);
        return;
    } else if ([requestPath hasPrefix:@"/batch"]) {
        CFStringRef contentLengthHeader = CFHTTPMessageCopyHeaderFieldValue(httpRequest, CFSTR("Content-Length"));
        NSInteger size = CFStringGetIntValue(contentLengthHeader); CFRelease(contentLengthHeader);
        CFMutableDataRef data = CFDataCreateMutable(NULL, 0);
        while (bytes > 0 || CFDataGetLength(data) < size) {
            if(bytes > 0) {
                CFDataAppendBytes(data, (UInt8 *)buffer, bytes);
            }
            bytes = recv(handle, buffer, sizeof(buffer) - 1, 0);
        }
        CFDataReplaceBytes(data, CFRangeMake(0, CFDataGetLength(data) - size), NULL, 0);
        
        const UInt8 *bytes = CFDataGetBytePtr(data);
        CFIndex length = CFDataGetLength(data);
        NSData *rangeData;
        NSMutableDictionary *_h = [[NSMutableDictionary alloc] init];
        NSInteger ptr = 0;
        NSString *stringData;
        NSMutableString *datahash = [NSMutableString stringWithCapacity:0x40];
        while (ptr < length) {
            NSData *slicedData = [NSData dataWithBytes:bytes + ptr + 0x20 length:0x28 - 0x20];
            uint64_t datalen = 0;
            [slicedData getBytes:&datalen length:sizeof(datalen)];
            datalen = CFSwapInt64LittleToHost(datalen);
            const UInt8 *datahash_bytes = bytes + ptr;
            datahash = [NSMutableString stringWithCapacity:0x40];
            for (int i = 0; i < 0x20; i++) {
                [datahash appendFormat:@"%02x", datahash_bytes[i]];
            }
            rangeData = [NSData dataWithBytes:bytes + (ptr + 0x28) length:datalen];
            _h[datahash] = rangeData;
            ptr += 0x28 + datalen;
        }
        CFRelease(data);
        stringData = [[NSString alloc] initWithData:rangeData encoding:NSUTF8StringEncoding];
        NSMutableArray *_q = [NSMutableArray array];
        NSArray *ops = @[@"BufferAlloc", @"BufferFree", @"CopyIn", @"CopyOut", @"ProgramAlloc", @"ProgramFree", @"ProgramExec"];
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"(%@)\\(", [ops componentsJoinedByString:@"|"]] options:0 error:nil];
        __block NSInteger lastIndex = 0;
        [regex enumerateMatchesInString:stringData options:0 range:NSMakeRange(0, stringData.length) usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
            NSRange range = NSMakeRange(lastIndex, match.range.location - lastIndex);
            [_q addObject:[[stringData substringWithRange:range] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", "]]];
            lastIndex = match.range.location;
        }];
        [_q addObject:[[stringData substringFromIndex:lastIndex] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", "]]];

        
        for (NSString *x in _q) {
            if ([x hasPrefix:@"BufferAlloc"]) {
                NSLog(@"BufferAlloc");
                NSString *pattern = @"buffer_num=(\\d+)";
                NSRange range = [[[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil] firstMatchInString:x options:0 range:NSMakeRange(0, x.length)] rangeAtIndex:1];
                NSString *buffer_num = [x substringWithRange:range];
                pattern = @"size=(\\d+)";
                range = [[[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil] firstMatchInString:x options:0 range:NSMakeRange(0, x.length)] rangeAtIndex:1];
                int size = [[x substringWithRange:range] intValue];
                [buffers setObject:[device newBufferWithLength:size options:MTLResourceStorageModeShared] forKey:buffer_num];
            } else if ([x hasPrefix:@"BufferFree"]) {
                NSLog(@"BufferFree");
                NSString *pattern = @"buffer_num=(\\d+)";
                NSRange range = [[[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil] firstMatchInString:x options:0 range:NSMakeRange(0, x.length)] rangeAtIndex:1];
                NSString *buffer_num = [x substringWithRange:range];
                [buffers removeObjectForKey: buffer_num];
            } else if ([x hasPrefix:@"CopyIn"]) {
                NSLog(@"CopyIn %@",x);
                NSString *pattern = @"buffer_num=(\\d+)";
                NSRange range = [[[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil] firstMatchInString:x options:0 range:NSMakeRange(0, x.length)] rangeAtIndex:1];
                NSString *buffer_num = [x substringWithRange:range];
                pattern = @"datahash='([^']+)'";
                range = [[[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil] firstMatchInString:x options:0 range:NSMakeRange(0, x.length)] rangeAtIndex:1];
                NSString *datahash = [x substringWithRange:range];
                id<MTLBuffer> buffer = buffers[buffer_num];
                NSData *data = _h[datahash];
                memcpy(buffer.contents, data.bytes, data.length);
            } else if ([x hasPrefix:@"CopyOut"]) {
                NSLog(@"copyout %@",x);
                for(int i = 0; i < mtl_buffers_in_flight.count; i++){
                    [mtl_buffers_in_flight[i] waitUntilCompleted];
                }
                [mtl_buffers_in_flight removeAllObjects];
                NSString *pattern = @"buffer_num=(\\d+)";
                NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                                       options:0
                                                                                         error:nil];
                NSTextCheckingResult *match = [regex firstMatchInString:x
                                                                options:0
                                                                  range:NSMakeRange(0, [x length])];
                NSString *buffer_num = [x substringWithRange:[match rangeAtIndex:1]];
                id<MTLBuffer> buffer = buffers[buffer_num];
                const void *rawData = buffer.contents;
                size_t bufferSize = buffer.length;
                char responseHeader[256];
                snprintf(responseHeader, sizeof(responseHeader),
                         "HTTP/1.1 200 OK\r\n"
                         "Content-Type: text/plain\r\n"
                         "Content-Length: %zu\r\n"
                         "Connection: close\r\n\r\n", bufferSize);
                send(handle, responseHeader, strlen(responseHeader), 0);
                send(handle, rawData, bufferSize, 0);
                return;
            } else if ([x hasPrefix:@"ProgramAlloc"]) {
                NSLog(@"ProgramAlloc");
                NSString *pattern = @"name='([^']+)'";
                NSRange range = [[[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil] firstMatchInString:x options:0 range:NSMakeRange(0, x.length)] rangeAtIndex:1];
                NSString *name = [x substringWithRange:range];
                pattern = @"datahash='([^']+)'";
                range = [[[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil] firstMatchInString:x options:0 range:NSMakeRange(0, x.length)] rangeAtIndex:1];
                NSString *datahash = [x substringWithRange:range];
                NSString *prg = [[NSString alloc] initWithData:_h[datahash] encoding:NSUTF8StringEncoding];
                NSError *error = nil;
                id<MTLLibrary> library = [device newLibraryWithSource:prg
                                                               options:nil
                                                                 error:&error];
                id<MTLFunction> func = [library newFunctionWithName:name];
                MTLComputePipelineDescriptor *descriptor = [[MTLComputePipelineDescriptor alloc] init];
                descriptor.computeFunction = func;
                descriptor.supportIndirectCommandBuffers = YES;
                MTLPipelineOption options = MTLPipelineOptionNone;
                MTLAutoreleasedComputePipelineReflection *reflection = nil;
                id<MTLComputePipelineState> pipeline_state = [device newComputePipelineStateWithDescriptor:descriptor
                                                                      options:options
                                                                   reflection:&reflection
                                                                        error:&error];
                [objects setObject:pipeline_state forKey:@[name,datahash]];
                [_h removeObjectForKey:datahash];
            } else if ([x hasPrefix:@"ProgramFree"]) {
                NSLog(@"ProgramFree");
            } else if ([x hasPrefix:@"ProgramExec"]) {
                NSLog(@"ProgramExec %@",x);
                NSString *pattern = @"name='([^']+)'";
                NSRange range = [[[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil] firstMatchInString:x options:0 range:NSMakeRange(0, x.length)] rangeAtIndex:1];
                NSString *name = [x substringWithRange:range];
                pattern = @"datahash='([^']+)'";
                range = [[[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil] firstMatchInString:x options:0 range:NSMakeRange(0, x.length)] rangeAtIndex:1];
                NSString *datahash = [x substringWithRange:range];
                                
                NSArray<NSString *> *gloal_sizes = extractValues(@"global_size=\\(([^)]+)\\)", x);
                NSArray<NSString *> *local_sizes = extractValues(@"local_size=\\(([^)]+)\\)", x);
                
                pattern = @"wait=(True|False)";
                range = [[[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil] firstMatchInString:x options:0 range:NSMakeRange(0, x.length)] rangeAtIndex:1];
                BOOL wait = [[x substringWithRange:range] isEqualToString:@"True"];
                                
                NSArray<NSString *> *bufsValues = extractValues(@"bufs=\\(([^)]+)\\)", x);
                NSArray<NSString *> *valsValues = extractValues(@"vals=\\(([^)]+)\\)", x);
                                
                id<MTLCommandBuffer> commandBuffer = [mtl_queue commandBuffer];
                id<MTLComputeCommandEncoder> computeEncoder = [commandBuffer computeCommandEncoder];
                [computeEncoder setComputePipelineState:objects[@[name,datahash]]];
                for(int i = 0; i < bufsValues.count; i++){
                    [computeEncoder setBuffer:buffers[bufsValues[i]] offset:0 atIndex:i];
                }
                for(int i = 0; i < valsValues.count; i++){
                    NSMutableData *data = [NSMutableData dataWithCapacity:valsValues.count * sizeof(NSInteger)];
                    NSInteger value = [valsValues[i] integerValue];
                    [data appendBytes:&value length:sizeof(NSInteger)];
                    [computeEncoder setBytes:data.bytes length:data.length atIndex:i+bufsValues.count];
                }
                MTLSize gridSize = MTLSizeMake([gloal_sizes[0] intValue], [gloal_sizes[1] intValue], [gloal_sizes[2] intValue]);
                MTLSize threadGroupSize = MTLSizeMake([local_sizes[0] intValue], [local_sizes[1] intValue], [local_sizes[2] intValue]);
                [computeEncoder dispatchThreadgroups:gridSize threadsPerThreadgroup:threadGroupSize];
                [computeEncoder endEncoding];
                [commandBuffer commit];
                if(wait) {
                    [commandBuffer waitUntilCompleted];
                    float time = (float)(commandBuffer.GPUEndTime - commandBuffer.GPUStartTime);
                    NSString *timeString = [NSString stringWithFormat:@"%e", time];
                    const char *timeCString = [timeString UTF8String];
                    size_t timeCStringLength = strlen(timeCString);
                    char header[256];
                    snprintf(header, sizeof(header),
                             "HTTP/1.1 200 OK\r\n"
                             "Content-Type: text/plain\r\n"
                             "Content-Length: %zu\r\n"
                             "Connection: close\r\n\r\n", timeCStringLength);
                    send(handle, header, strlen(header), 0);
                    send(handle, timeCString, timeCStringLength, 0);
                    return;
                }
                [mtl_buffers_in_flight addObject: commandBuffer];
            } else {
                NSLog(@"No op found %@",x);
            }
        }
        return;
    }
}
@end
