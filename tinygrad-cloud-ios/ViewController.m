#import "ViewController.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <ifaddrs.h>
#import <arpa/inet.h>

@interface ViewController ()
@property (nonatomic) CFSocketRef socket;
@end

@implementation ViewController

id<MTLDevice> device;
NSMutableDictionary<NSString *, id> *pipeline_states;
NSMutableDictionary<NSString *, id> *buffers;
NSMutableArray<id<MTLCommandBuffer>> *mtl_buffers_in_flight;
id<MTLCommandQueue> mtl_queue;


- (void)viewDidLoad {
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    pipeline_states = [[NSMutableDictionary alloc] init];
    buffers = [[NSMutableDictionary alloc] init];
    device = MTLCreateSystemDefaultDevice();
    mtl_queue = [device newCommandQueueWithMaxCommandBufferCount:1024];
    mtl_buffers_in_flight = [[NSMutableArray alloc] init];
    [super viewDidLoad];
    UILabel *l = [[UILabel alloc] initWithFrame:self.view.bounds]; l.textAlignment = 1; l.numberOfLines = 0; [self.view addSubview:l];
    [self updateIPLabel:l];
    [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(__unused NSTimer *_) { [self updateIPLabel:l]; }];
    UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem]; b.frame=CGRectMake(self.view.center.x-50,self.view.center.y+40,100,30); [b setTitle:@"Help" forState:0]; [b addAction:[UIAction actionWithHandler:^(__kindof UIAction *_) { [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/roryclear/tinygrad-remote-ios/blob/main/README.md"] options:@{} completionHandler:nil]; }] forControlEvents:UIControlEventTouchUpInside]; [self.view addSubview:b];
    self.socket = CFSocketCreate(NULL, PF_INET, SOCK_STREAM, IPPROTO_TCP, kCFSocketAcceptCallBack, AcceptCallback, NULL);
    while (!self.socket) { sleep(1); self.socket = CFSocketCreate(NULL, PF_INET, SOCK_STREAM, IPPROTO_TCP, kCFSocketAcceptCallBack, AcceptCallback, NULL); }
    struct sockaddr_in address; memset(&address, 0, sizeof(address)); address.sin_len = sizeof(address); address.sin_port = htons(6667); address.sin_addr.s_addr = INADDR_ANY;
    CFDataRef address_data = CFDataCreate(NULL, (const UInt8 *)&address, sizeof(address));
    while (CFSocketSetAddress(self.socket, address_data) != kCFSocketSuccess) sleep(1);
    CFRunLoopSourceRef source = CFSocketCreateRunLoopSource(NULL, self.socket, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
    NSLog(@"HTTP Server started on port 6667.");
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
- (BOOL)shouldAutorotate { return NO; }

- (void)updateIPLabel:(UILabel *)label {
    struct ifaddrs *a = 0;
    getifaddrs(&a);
    NSString *ip = nil;
    while (a) {
        if (a->ifa_addr->sa_family == AF_INET &&
            [[NSString stringWithUTF8String:a->ifa_name] isEqualToString:@"en0"]) {
            ip = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)a->ifa_addr)->sin_addr)];
            break;
        }
        a = a->ifa_next;
    }
    label.text = ip ? [NSString stringWithFormat:@"device ip: %@:6667", ip] : @"Waiting for WiFi...";
}

void sendHTTPResponse(CFSocketNativeHandle handle, const void *data, size_t dataSize) {
    char response_header[256];
    snprintf(response_header, sizeof(response_header),
             "HTTP/1.1 200 OK\r\n"
             "Content-Type: text/plain\r\n"
             "Content-Length: %zu\r\n"
             "Connection: close\r\n\r\n", dataSize);
    send(handle, response_header, strlen(response_header), 0);
    send(handle, data, dataSize, 0);
    close(handle);
}

NSMutableDictionary<NSString *, id> *extractValues(NSString *x) {
    NSMutableDictionary<NSString *, id> *values = [@{@"op": [x componentsSeparatedByString:@"("][0]} mutableCopy];
    NSDictionary<NSString *, NSString *> *patterns = @{@"name": @"name='([^']+)'",@"datahash": @"datahash='([^']+)'",@"global_sizes": @"global_size=\\(([^)]+)\\)",
        @"local_sizes": @"local_size=\\(([^)]+)\\)",@"wait": @"wait=(True|False)",@"bufs": @"bufs=\\(([^)]+)\\)",@"vals": @"vals=\\(([^)]+)\\)",
        @"buffer_num": @"buffer_num=(\\d+)",@"size": @"size=(\\d+)"};
    [patterns enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *pattern, BOOL *stop) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
        NSTextCheckingResult *match = [regex firstMatchInString:x options:0 range:NSMakeRange(0, x.length)];
        if (match) {
            NSString *contents = [x substringWithRange:[match rangeAtIndex:1]];
            NSMutableArray<NSString *> *extracted_values = [NSMutableArray array];
            for (NSString *value in [contents componentsSeparatedByString:@","]) {
                NSString *trimmed_value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (trimmed_value.length > 0) {
                    [extracted_values addObject:trimmed_value];
                }
            }
            values[key] = [extracted_values copy];
        }
    }];
    return values;
}

static void AcceptCallback(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address, const void *data_in, void *info) {
    CFSocketNativeHandle handle = *(CFSocketNativeHandle *)data_in;
    char buffer[1024 * 500] = {0};
    struct timeval timeout;
    timeout.tv_sec = 10;
    setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, (const char *)&timeout, sizeof(timeout));
    ssize_t bytes_in = recv(handle, buffer, sizeof(buffer) - 1, 0);
    buffer[bytes_in] = '\0';
    CFDataRef data_ref = CFDataCreate(NULL, (UInt8 *)buffer, (CFIndex)bytes_in);
    CFHTTPMessageRef http_request = CFHTTPMessageCreateEmpty(NULL, TRUE);
    CFHTTPMessageAppendBytes(http_request, CFDataGetBytePtr(data_ref), CFDataGetLength(data_ref));
    CFStringRef content_length = CFHTTPMessageCopyHeaderFieldValue(http_request, CFSTR("Content-Length"));
    NSInteger size = CFStringGetIntValue(content_length);
    CFMutableDataRef data = CFDataCreateMutable(NULL, 0);
    NSInteger header_idx = -1;
    while (1) {
        CFDataAppendBytes(data, (UInt8 *)buffer, bytes_in);
        if (header_idx == -1) {
            CFDataRef h_data = CFStringCreateExternalRepresentation(NULL, CFSTR("\r\n\r\n"), kCFStringEncodingASCII, 0);
            for (CFIndex i = 0; i <= CFDataGetLength(data) - CFDataGetLength(h_data); i++) {
                if (memcmp(CFDataGetBytePtr(data) + i, CFDataGetBytePtr(h_data), CFDataGetLength(h_data)) == 0) {
                    header_idx = i + CFDataGetLength(h_data);
                    break;
                }
            }
        }
        if(CFDataGetLength(data) >= size + header_idx) break;
        bytes_in = recv(handle, buffer, sizeof(buffer) - 1, 0);
    }
    shutdown(handle, SHUT_RD);
    CFDataReplaceBytes(data, CFRangeMake(0, CFDataGetLength(data) - size), NULL, 0);
    const UInt8 *bytes = CFDataGetBytePtr(data);
    NSData *range_data;
    NSMutableDictionary *_h = [[NSMutableDictionary alloc] init];
    NSInteger ptr = 0;
    NSString *string_data;
    NSMutableString *datahash = [NSMutableString stringWithCapacity:0x40];
    while (ptr < size) {
        NSData *slicedData = [NSData dataWithBytes:bytes + ptr + 0x20 length:0x28 - 0x20];
        uint64_t datalen = 0;
        [slicedData getBytes:&datalen length:sizeof(datalen)];
        datalen = CFSwapInt64LittleToHost(datalen);
        const UInt8 *datahash_bytes = bytes + ptr;
        datahash = [NSMutableString stringWithCapacity:0x40];
        for (int i = 0; i < 0x20; i++) {
            [datahash appendFormat:@"%02x", datahash_bytes[i]];
        }
        range_data = [NSData dataWithBytes:bytes + (ptr + 0x28) length:datalen];
        _h[datahash] = range_data;
        ptr += 0x28 + datalen;
    }
    CFRelease(data);
    string_data = [[NSString alloc] initWithData:range_data encoding:NSUTF8StringEncoding];
    NSMutableArray *_q = [NSMutableArray array];
    NSArray *ops = @[@"BufferAlloc", @"BufferFree", @"CopyIn", @"CopyOut", @"ProgramAlloc", @"ProgramFree", @"ProgramExec", @"GetProperties"];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"(%@)\\(", [ops componentsJoinedByString:@"|"]] options:0 error:nil];
    __block NSInteger lastIndex = 0;
    [regex enumerateMatchesInString:string_data options:0 range:NSMakeRange(0, string_data.length) usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
        [_q addObject:extractValues([[string_data substringWithRange:NSMakeRange(lastIndex, match.range.location - lastIndex)] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", "]])];
        lastIndex = match.range.location;
    }];
    [_q addObject:extractValues([[string_data substringFromIndex:lastIndex] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", "]])];
    for (NSMutableDictionary *values in _q) {
        if ([values[@"op"] isEqualToString:@"GetProperties"]) {
            char *response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nRemoteProperties(real_device='METAL', renderer=('tinygrad.renderer.cstyle', 'MetalRenderer', ()), graph_supported=False, graph_supports_multi=False, transfer_supported=False, offset_supported=False)";
            send(handle, response, strlen(response), 0);
            close(handle);
            return;
        } else if ([values[@"op"] isEqualToString:@"BufferAlloc"]) {
            [buffers setObject:[device newBufferWithLength:[values[@"size"][0] intValue] options:MTLResourceStorageModeShared] forKey:values[@"buffer_num"][0]];
        } else if ([values[@"op"] isEqualToString:@"BufferFree"]) {
            [buffers removeObjectForKey: values[@"buffer_num"][0]];
        } else if ([values[@"op"] isEqualToString:@"CopyIn"]) {
            id<MTLBuffer> buffer = buffers[values[@"buffer_num"][0]];
            NSData *data = _h[values[@"datahash"][0]];
            memcpy(buffer.contents, data.bytes, data.length);
        } else if ([values[@"op"] isEqualToString:@"CopyOut"]) {
            for(int i = 0; i < mtl_buffers_in_flight.count; i++){
                [mtl_buffers_in_flight[i] waitUntilCompleted];
            }
            [mtl_buffers_in_flight removeAllObjects];
            id<MTLBuffer> buffer = buffers[values[@"buffer_num"][0]];
            const void *rawData = buffer.contents;
            sendHTTPResponse(handle, rawData, buffer.length);
            return;
        } else if ([values[@"op"] isEqualToString:@"ProgramAlloc"]) {
            if ([pipeline_states objectForKey:@[values[@"name"][0],values[@"datahash"][0]]]) continue;
            NSString *prg = [[NSString alloc] initWithData:_h[values[@"datahash"][0]] encoding:NSUTF8StringEncoding];
            NSError *error = nil;
            id<MTLLibrary> library = [device newLibraryWithSource:prg
                                                          options:nil
                                                            error:&error];
            MTLComputePipelineDescriptor *descriptor = [[MTLComputePipelineDescriptor alloc] init];
            descriptor.computeFunction = [library newFunctionWithName:values[@"name"][0]];;
            descriptor.supportIndirectCommandBuffers = YES;
            MTLComputePipelineReflection *reflection = nil;
            id<MTLComputePipelineState> pipeline_state = [device newComputePipelineStateWithDescriptor:descriptor
                                                                                               options:MTLPipelineOptionNone
                                                                                            reflection:&reflection
                                                                                                 error:&error];
            [pipeline_states setObject:pipeline_state forKey:@[values[@"name"][0],values[@"datahash"][0]]];
        } else if ([values[@"op"] isEqualToString:@"ProgramFree"]) {
            [pipeline_states removeObjectForKey:@[values[@"name"][0],values[@"datahash"][0]]];
        } else if ([values[@"op"] isEqualToString:@"ProgramExec"]) {
            NSInteger max_size = [pipeline_states[@[values[@"name"][0],values[@"datahash"][0]]] maxTotalThreadsPerThreadgroup];
            if(max_size < [values[@"local_sizes"][0] intValue]*[values[@"local_sizes"][1] intValue]*[values[@"local_sizes"][2] intValue]) {
                sendHTTPResponse(handle, "inf", 3);
                return;
            }
            id<MTLCommandBuffer> command_buffer = [mtl_queue commandBuffer];
            id<MTLComputeCommandEncoder> encoder = [command_buffer computeCommandEncoder];
            [encoder setComputePipelineState:pipeline_states[@[values[@"name"][0],values[@"datahash"][0]]]];
            for(int i = 0; i < [(NSArray *)values[@"bufs"] count]; i++){
                [encoder setBuffer:buffers[values[@"bufs"][i]] offset:0 atIndex:i];
            }
            for (int i = 0; i < [(NSArray *)values[@"vals"] count]; i++) {
                NSInteger value = [values[@"vals"][i] integerValue];
                [encoder setBytes:&value length:sizeof(NSInteger) atIndex:i + [(NSArray *)values[@"bufs"] count]];
            }
            MTLSize global_size = MTLSizeMake([values[@"global_sizes"][0] intValue], [values[@"global_sizes"][1] intValue], [values[@"global_sizes"][2] intValue]);
            MTLSize local_size = MTLSizeMake([values[@"local_sizes"][0] intValue], [values[@"local_sizes"][1] intValue], [values[@"local_sizes"][2] intValue]);
            [encoder dispatchThreadgroups:global_size threadsPerThreadgroup:local_size];
            [encoder endEncoding];
            [command_buffer commit];
            if([values[@"wait"][0] isEqualToString:@"True"]) {
                [command_buffer waitUntilCompleted];
                float time = (float)(command_buffer.GPUEndTime - command_buffer.GPUStartTime);
                const char *time_string = [[NSString stringWithFormat:@"%e", time] UTF8String];
                sendHTTPResponse(handle, time_string, strlen(time_string));
            }
            [mtl_buffers_in_flight addObject: command_buffer];
        }
    }
    sendHTTPResponse(handle, (const char[]){0x00}, 1); // if sending batches on copyin in tinygrad to load larger models, see run times etc.
}
@end

