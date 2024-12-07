#import "ViewController.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <Foundation/Foundation.h>

@interface ViewController ()
@property (nonatomic) CFSocketRef socket;
@end

@implementation ViewController


- (void)viewDidLoad {
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
    NSLog(@"callback??");
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
        NSMutableDictionary *h = [[NSMutableDictionary alloc] init];
        NSInteger ptr = 0;
        while(ptr < length){
            NSData *slicedData = [NSData dataWithBytes:bytes + ptr+0x20 length:0x28 - 0x20];
            uint64_t datalen = 0;
            [slicedData getBytes:&datalen length:sizeof(datalen)];
            datalen = CFSwapInt64LittleToHost(datalen);
            NSLog(@"datalen: %llu", datalen);
            const UInt8 *datahash_bytes = bytes + ptr;
            NSMutableString *datahash = [NSMutableString stringWithCapacity:0x40];
            for (int i = 0; i < 0x20; i++) [datahash appendFormat:@"%02x", datahash_bytes[i]];
            NSLog(@"datahash =%@",datahash);
            const UInt8 *subBytes = bytes + (ptr + 0x28);
            rangeData = [NSData dataWithBytes:subBytes length:datalen];
            h[datahash] = [[NSString alloc] initWithData:rangeData encoding:NSUTF8StringEncoding]; NSLog(@"rangeData = %@", [[NSString alloc] initWithData:rangeData encoding:NSUTF8StringEncoding]);
            ptr += 0x28 + datalen;
        }
        
        NSString *input = [[NSString alloc] initWithData:rangeData encoding:NSUTF8StringEncoding];
        NSLog(@"intput =%@\n", input);
        
        NSArray *ops = @[@"BufferAlloc", @"BufferFree", @"CopyIn", @"CopyOut", @"ProgramAlloc", @"ProgramFree", @"ProgramExec"];
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"(%@)\\(", [ops componentsJoinedByString:@"|"]] options:0 error:nil];
        input = [input stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"[]"]];
        NSMutableArray *results = [NSMutableArray array];
        __block NSInteger lastIndex = 0;
        [regex enumerateMatchesInString:input options:0 range:NSMakeRange(0, input.length) usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
            if (match.range.location > lastIndex) {
                NSString *substring = [input substringWithRange:NSMakeRange(lastIndex, match.range.location - lastIndex)];
                substring = [substring stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", "]];
                [results addObject:substring];
            }
            lastIndex = match.range.location;
        }];
        if (lastIndex < input.length) {
            NSString *substring = [input substringFromIndex:lastIndex];
            substring = [substring stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", "]];
            [results addObject:substring];
        }
        NSLog(@"%@", results);
        
        NSLog(@"%@", h);

        
        NSMutableString *output = [NSMutableString stringWithCapacity:length * 2];
        NSLog(@"%@", output);
        const char *header = "HTTP/1.1 200 OK\r\n"
                             "Content-Type: text/plain\r\n"
                             "Content-Length: 4\r\n"
                             "Connection: close\r\n\r\n";
        const char body[] = {0x00, 'U', '$', 'G'};
        send(handle, header, strlen(header), 0);
        send(handle, body, sizeof(body), 0);
        return;
    }
}
@end
