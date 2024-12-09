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
        
        //tinygrad decentralise???
        NSData *rangeData;
        NSMutableDictionary *_h = [[NSMutableDictionary alloc] init];
        NSMutableString *datahash;
        NSInteger ptr = 0;
        while(ptr < length){
            NSData *slicedData = [NSData dataWithBytes:bytes + ptr+0x20 length:0x28 - 0x20];
            uint64_t datalen = 0;
            [slicedData getBytes:&datalen length:sizeof(datalen)];
            datalen = CFSwapInt64LittleToHost(datalen);
            const UInt8 *datahash_bytes = bytes + ptr;
            datahash = [NSMutableString stringWithCapacity:0x40];
            for (int i = 0; i < 0x20; i++) [datahash appendFormat:@"%02x", datahash_bytes[i]];
            rangeData = [NSData dataWithBytes:bytes + (ptr + 0x28) length:datalen];
            _h[datahash] = [[NSString alloc] initWithData:rangeData encoding:NSUTF8StringEncoding];
            ptr += 0x28 + datalen;
        }
        
        NSString *input = [[NSString alloc] initWithData:rangeData encoding:NSUTF8StringEncoding];
        NSArray *ops = @[@"BufferAlloc", @"BufferFree", @"CopyIn", @"CopyOut", @"ProgramAlloc", @"ProgramFree", @"ProgramExec"];
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"(%@)\\(", [ops componentsJoinedByString:@"|"]] options:0 error:nil];
        input = [input stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"[]"]];
        NSMutableArray *_q = [NSMutableArray array];
        __block NSInteger lastIndex = 0;
        [regex enumerateMatchesInString:input options:0 range:NSMakeRange(0, input.length) usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
            if (match.range.location > lastIndex) {
                NSString *substring = [input substringWithRange:NSMakeRange(lastIndex, match.range.location - lastIndex)];
                substring = [substring stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", "]];
                [_q addObject:substring];
            }
            lastIndex = match.range.location;
        }];
        if (lastIndex < input.length) {
            NSString *substring = [input substringFromIndex:lastIndex];
            substring = [substring stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", "]];
            [_q addObject:substring];
        }
        //NSLog(@"%@", _q);
        //NSLog(@"%@", _h);
        
        for (NSString *x in _q) {
            if ([x hasPrefix:@"BufferAlloc"]) {
                NSLog(@"BufferAlloc");
                NSString *pattern = @"buffer_num=(\\d+)";
                NSRange range = [[[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil] firstMatchInString:x options:0 range:NSMakeRange(0, x.length)] rangeAtIndex:1];
                NSString *buffer_num = [x substringWithRange:range];
                pattern = @"size=(\\d+)";
                range = [[[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil] firstMatchInString:x options:0 range:NSMakeRange(0, x.length)] rangeAtIndex:1];
                int size = [[x substringWithRange:range] intValue];
                id<MTLBuffer> buffer = [device newBufferWithLength:size options:MTLResourceStorageModeShared];
                [buffers setObject:buffer forKey:buffer_num];
            } else if ([x hasPrefix:@"BufferFree"]) {
                NSLog(@"BufferFree");
            } else if ([x hasPrefix:@"CopyIn"]) {
                NSLog(@"CopyIn");
            } else if ([x hasPrefix:@"CopyOut"]) {
                NSLog(@"CopyOut");
                const char *header = "HTTP/1.1 200 OK\r\n"
                                     "Content-Type: text/plain\r\n"
                                     "Content-Length: 4\r\n"
                                     "Connection: close\r\n\r\n";
                const char body[] = {0x00, 'U', '$', 'G'}; //todo
                send(handle, header, strlen(header), 0);
                send(handle, body, sizeof(body), 0);
                return;
            } else if ([x hasPrefix:@"ProgramAlloc"]) {
                NSLog(@"ProgramAlloc");
                NSLog(@"%@",x);
                NSString *pattern = @"name='([^']+)'";
                NSRange range = [[[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil] firstMatchInString:x options:0 range:NSMakeRange(0, x.length)] rangeAtIndex:1];
                NSString *name = [x substringWithRange:range];
                pattern = @"datahash='([^']+)'";
                range = [[[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil] firstMatchInString:x options:0 range:NSMakeRange(0, x.length)] rangeAtIndex:1];
                NSString *datahash = [x substringWithRange:range];
                NSString *prg = _h[datahash];
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
            } else if ([x hasPrefix:@"ProgramFree"]) {
                NSLog(@"ProgramFree");
            } else if ([x hasPrefix:@"ProgramExec"]) {
                NSLog(@"ProgramExec");
                NSString *pattern = @"name='([^']+)'";
                NSRange range = [[[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil] firstMatchInString:x options:0 range:NSMakeRange(0, x.length)] rangeAtIndex:1];
                NSString *name = [x substringWithRange:range];
                pattern = @"datahash='([^']+)'";
                range = [[[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil] firstMatchInString:x options:0 range:NSMakeRange(0, x.length)] rangeAtIndex:1];
                NSString *datahash = [x substringWithRange:range];
                
                pattern = @"global_size=\\((\\d+), (\\d+), (\\d+)\\)";
                NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
                NSTextCheckingResult *match = [regex firstMatchInString:x options:0 range:NSMakeRange(0, x.length)];
                NSInteger gx = [[x substringWithRange:[match rangeAtIndex:1]] integerValue];
                NSInteger gy = [[x substringWithRange:[match rangeAtIndex:2]] integerValue];
                NSInteger gz = [[x substringWithRange:[match rangeAtIndex:3]] integerValue];
                
                pattern = @"local_size=\\((\\d+), (\\d+), (\\d+)\\)";
                regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
                match = [regex firstMatchInString:x options:0 range:NSMakeRange(0, x.length)];
                NSInteger lx = [[x substringWithRange:[match rangeAtIndex:1]] integerValue];
                NSInteger ly = [[x substringWithRange:[match rangeAtIndex:2]] integerValue];
                NSInteger lz = [[x substringWithRange:[match rangeAtIndex:3]] integerValue];
                
                pattern = @"bufs=\\(([^)]+)\\)";
                regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
                range = [[regex firstMatchInString:x options:0 range:NSMakeRange(0, x.length)] rangeAtIndex:1];
                NSString *bufsContents = [x substringWithRange:range];
                NSArray<NSString *> *bufsRawValues = [bufsContents componentsSeparatedByString:@","];
                NSMutableArray<NSString *> *bufsValues = [NSMutableArray array];
                for (NSString *value in bufsRawValues) {
                    NSString *trimmedValue = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (trimmedValue.length > 0) {
                        [bufsValues addObject:trimmedValue];
                    }
                }
                
                id<MTLCommandBuffer> commandBuffer = [mtl_queue commandBuffer];
                id<MTLComputeCommandEncoder> computeEncoder = [commandBuffer computeCommandEncoder];
                [computeEncoder setComputePipelineState:objects[@[name,datahash]]];
                for(int i = 0; i < bufsValues.count; i++){
                    [computeEncoder setBuffer:buffers[bufsValues[i]] offset:0 atIndex:i];
                }
                MTLSize gridSize = MTLSizeMake(gx,gy,gz);
                MTLSize threadGroupSize = MTLSizeMake(lx, ly, lz);
                [computeEncoder dispatchThreads:gridSize
                          threadsPerThreadgroup:threadGroupSize];
                [computeEncoder endEncoding];
                [commandBuffer commit];
                [mtl_buffers_in_flight addObject: commandBuffer];
            } else {
                NSLog(@"No op found");
            }
        }
        
        NSMutableString *output = [NSMutableString stringWithCapacity:length * 2];
        NSLog(@"%@", output);
        return; //todo, response if not copyout at the end?
    }
}
@end
