/// Copyright 2015 Google Inc. All rights reserved.
///
/// Licensed under the Apache License, Version 2.0 (the "License");
/// you may not use this file except in compliance with the License.
/// You may obtain a copy of the License at
///
///    http://www.apache.org/licenses/LICENSE-2.0
///
///    Unless required by applicable law or agreed to in writing, software
///    distributed under the License is distributed on an "AS IS" BASIS,
///    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
///    See the License for the specific language governing permissions and
///    limitations under the License.

#import "MOLFCMClient.h"

#import <SystemConfiguration/SystemConfiguration.h>

#import <MOLAuthenticatingURLSession/MOLAuthenticatingURLSession.h>

/**  The FCM production host URL. */
static NSString *const kFCMHost = @"https://fcm-stream.googleapis.com";

/**  The FCM long poll component for receiving messages. */
static NSString *const kFCMMessagesBindPath = @"/fcm/connect/bind";

/**  The FCM component for posting message acknowledgements. */
static NSString *const kFCMMessagesAckPath = @"/fcm/connect/ack";

/**  HTTP Header Constants */
static NSString *const kFCMApplicationJSON = @"application/json";
static NSString *const kFCMContentType = @"Content-Type";

/**  Default 15 minute backoff maximum */
static const uint32_t kDefaultBackoffMaxSeconds = 900;

/**  Default 10 sec connect delay maximum */
static const uint32_t kDefaultConnectDelayMaxSeconds = 10;

#pragma mark MOLFCMClient Extension

@interface MOLFCMClient() {
  /**  URL components for receiving and acknowledging messages. */
  NSURLComponents *_bindComponents;
  NSURLComponents *_acknowledgeComponents;

  /**  Holds the NSURLSession object generated by the MOLAuthenticatingURLSession object. */
  NSURLSession *_session;

  /**  Holds the current backoff seconds. */
  uint32_t _backoffSeconds;

  /**  Holds the max connect and backoff seconds. */
  uint32_t _connectDelayMaxSeconds;
  uint32_t _backoffMaxSeconds;

  NSArray<NSNumber *> *_fatalHTTPStatusCodes;
}

/**  NSURLSession wrapper used for https communication with the FCM service. */
@property(nonatomic) MOLAuthenticatingURLSession *authSession;

/**  The block to be called for every message. */
@property(copy, nonatomic) MOLFCMMessageHandler messageHandler;

/**  Is used throughout the class to reconnect to FCM after a connection loss. */
@property SCNetworkReachabilityRef reachability;

/**  Called by the reachability handler when the host becomes reachable. */
- (void)reachabilityRestored;

@end

#pragma mark SCNetworkReachabilityCallBack

/**  Called when the network state changes. */
static void reachabilityHandler(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags,
                                void *info) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (flags & kSCNetworkReachabilityFlagsReachable) {
      MOLFCMClient *FCMClient = (__bridge MOLFCMClient *)info;
      SEL s = @selector(reachabilityRestored);
      [NSObject cancelPreviousPerformRequestsWithTarget:FCMClient selector:s object:nil];
      [FCMClient performSelector:s withObject:nil afterDelay:1];
    }
  });
}

@implementation MOLFCMClient

#pragma mark init/dealloc methods

- (instancetype)initWithFCMToken:(NSString *)FCMToken
                            host:(NSString *)host
                 connectDelayMax:(uint32_t)connectDelayMax
                      backoffMax:(uint32_t)backoffMax
                      fatalCodes:(NSArray<NSNumber *> *)fatalCodes
            sessionConfiguration:(NSURLSessionConfiguration *)sessionConfiguration
                  messageHandler:(MOLFCMMessageHandler)messageHandler {
  self = [super init];
  if (self) {
    _FCMToken = [FCMToken copy];
    _bindComponents = [NSURLComponents componentsWithString:host ?: kFCMHost];
    _bindComponents.path = kFCMMessagesBindPath;
    NSURLQueryItem *tokenQuery = [NSURLQueryItem queryItemWithName:@"token" value:FCMToken];
    if (tokenQuery) {
      _bindComponents.queryItems = @[ tokenQuery ];
    }

    _acknowledgeComponents = [NSURLComponents componentsWithString:host ?: kFCMHost];
    _acknowledgeComponents.path = kFCMMessagesAckPath;
    _messageHandler = messageHandler;

    _authSession =
        [[MOLAuthenticatingURLSession alloc] initWithSessionConfiguration:
            sessionConfiguration ?: [NSURLSessionConfiguration defaultSessionConfiguration]];
    _authSession.dataTaskDidReceiveDataBlock = [self dataTaskDidReceiveDataBlock];
    _authSession.taskDidCompleteWithErrorBlock = [self taskDidCompleteWithErrorBlock];

    _session = _authSession.session;

    _connectDelayMaxSeconds = connectDelayMax ?: kDefaultConnectDelayMaxSeconds;
    _backoffMaxSeconds = backoffMax ?: kDefaultBackoffMaxSeconds;
    _fatalHTTPStatusCodes = fatalCodes ?: @[@302, @400, @403];
  }
  return self;
}

- (instancetype)initWithFCMToken:(NSString *)FCMToken
            sessionConfiguration:(NSURLSessionConfiguration *)sessionConfiguration
                  messageHandler:(MOLFCMMessageHandler)messageHandler {
  return [self initWithFCMToken:FCMToken
                           host:nil
                connectDelayMax:0
                     backoffMax:0
                     fatalCodes:nil
           sessionConfiguration:sessionConfiguration
                 messageHandler:messageHandler];
}

- (instancetype)initWithFCMToken:(NSString *)FCMToken
                  messageHandler:(MOLFCMMessageHandler)messageHandler {
  return [self initWithFCMToken:FCMToken
                           host:nil
                connectDelayMax:0
                     backoffMax:0
                     fatalCodes:nil
           sessionConfiguration:nil
                 messageHandler:messageHandler];
}

/**  Before this object is released ensure reachability release. */
- (void)dealloc {
  [self stopReachability];
}

- (NSString *)description {
  return [NSString stringWithFormat:@"<MOLFCMClient: %p>\nbind: %@\nack: %@",
             self, _bindComponents.URL, _acknowledgeComponents.URL];
}

#pragma mark property methods

- (void)setLoggingBlock:(void (^)(NSString *))loggingBlock {
  self.authSession.loggingBlock = _loggingBlock = loggingBlock;
}

- (BOOL)isConnected {
  for (NSURLSessionDataTask *dataTask in [self dataTasks]) {
    if (dataTask.state == NSURLSessionTaskStateRunning) return YES;
  }
  return NO;
}

#pragma mark reachability methods

- (void)reachabilityRestored {
#ifdef DEBUG
  NSString *log = @"Reachability restored. Reconnect after a backoff of %i seconds";
  [self log:[NSString stringWithFormat:log, _backoffSeconds]];
#endif
  [self stopReachability];
  dispatch_time_t t = dispatch_time(DISPATCH_TIME_NOW, _backoffSeconds * NSEC_PER_SEC);
  dispatch_after(t, dispatch_get_main_queue(), ^{
    [self connectHelper];
  });
}

/**  Start listening for network state changes on a background thread. */
- (void)startReachability {
  if (self.reachability) return;
#ifdef DEBUG
  [self log:@"Reachability started."];
#endif
  self.reachability = SCNetworkReachabilityCreateWithName(kCFAllocatorDefault,
                                                          _bindComponents.host.UTF8String);
  SCNetworkReachabilityContext context = {
    .info = (__bridge void *)self
  };
  if (SCNetworkReachabilitySetCallback(self.reachability, reachabilityHandler, &context)) {
    SCNetworkReachabilitySetDispatchQueue(
        self.reachability, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
  }
}

/**  Stop listening for network state changes. */
- (void)stopReachability {
  if (self.reachability) {
    SCNetworkReachabilitySetDispatchQueue(self.reachability, NULL);
    if (self.reachability) CFRelease(self.reachability);
    self.reachability = NULL;
  }
}

#pragma mark message methods

- (void)connect {
  uint32_t ms = arc4random_uniform(_connectDelayMaxSeconds * 1000);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    [self connectHelper];
  });
}

- (void)connectHelper {
#ifdef DEBUG
  [self log:@"Connecting..."];
#endif
  [self cancelConnections];
  NSMutableURLRequest *URLRequest = [NSMutableURLRequest requestWithURL:_bindComponents.URL];
  [URLRequest addValue:kFCMApplicationJSON forHTTPHeaderField:kFCMContentType];
  URLRequest.HTTPMethod = @"GET";
  [[_session dataTaskWithRequest:URLRequest] resume];
}

- (void)acknowledgeMessage:(NSDictionary *)message {
  if (self.FCMToken && message[@"message_id"]) {
    NSMutableURLRequest *URLRequest =
        [NSMutableURLRequest requestWithURL:_acknowledgeComponents.URL];
    URLRequest.HTTPMethod = @"POST";
    [URLRequest addValue:kFCMApplicationJSON forHTTPHeaderField:kFCMContentType];
    NSDictionary *ack = @{ @"token" : self.FCMToken,
                           @"message_id" : message[@"message_id"] };
    URLRequest.HTTPBody = [NSJSONSerialization dataWithJSONObject:ack options:0 error:NULL];
    [[_session dataTaskWithRequest:URLRequest
                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
      if (((NSHTTPURLResponse *)response).statusCode != 200) {
        if (self.acknowledgeErrorHandler) {
          self.acknowledgeErrorHandler(message, error);
        }
      }
    }] resume];
  }
}

- (void)disconnect {
  [self stopReachability];
  [_session invalidateAndCancel];
}

- (void)cancelConnections {
  for (NSURLSessionDataTask *dataTask in [self dataTasks]) {
    [dataTask cancel];
  }
}

- (NSArray<NSURLSessionDataTask *> *)dataTasks {
  __block NSArray *dataTasks;
  dispatch_semaphore_t sema = dispatch_semaphore_create(0);
  [_session getTasksWithCompletionHandler:^(NSArray *data, NSArray *upload, NSArray *download) {
    dataTasks = data;
    dispatch_semaphore_signal(sema);
  }];
  dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
  return dataTasks;
}

/**
 *  Parse FCM data; extract and call self.messageHandler for each message.
 *
 *  Expected format:
 *    10
 *    [[0,[{}]]]10
 *    [[1,[{}]]]
 *
 */
- (void)processMessagesFromData:(NSData *)data {
  if (!data) return;

  // Get the string representation of the data
  NSMutableString *raw = [[NSMutableString alloc] initWithData:data encoding:NSUTF8StringEncoding];

  // Loop until all of the messages are digested
  while (1) {
    // At the start of each loop raw should contain the length of the next message followed
    // by a new line
    NSInteger length = [raw integerValue];
    if (!length) break;

    // Remove the length line
    NSRange r = [raw rangeOfString:@"\n"];
    if (r.location == NSNotFound) break;
    [raw deleteCharactersInRange:NSMakeRange(0, r.location + 1)];

    // Read the next message
    if (length > raw.length) break;
    NSData *messageData = [[raw substringToIndex:length] dataUsingEncoding:NSUTF8StringEncoding];
    [raw deleteCharactersInRange:NSMakeRange(0, length)];

    // Parse the message
    id JSONObject = [NSJSONSerialization JSONObjectWithData:messageData options:0 error:NULL];

    // Ensure the message is in the proper format and handle it
    NSDictionary *message = [self extractMessageFrom:JSONObject];
    if ([message[@"message_type"] isEqualToString:@"control"] &&
        [message[@"control_type"] isEqualToString:@"CONNECTION_DRAINING"]) {
      return [self cancelConnections];
    } else if (message) {
      self.messageHandler(message);
    }
  }
}

/**
 *  Extract the enclosed message
 *
 *  @param jo The JSON object containing the message
 *
 *  @return An NSDictionary message
 */
- (NSDictionary *)extractMessageFrom:(id)jo {
  if (!jo) return nil;
  if (![jo isKindOfClass:[NSArray class]]) return nil;
  if (![[jo firstObject] isKindOfClass:[NSArray class]]) return nil;
  if (![[[jo firstObject] lastObject] isKindOfClass:[NSArray class]]) return nil;
  if (![[[[jo firstObject] lastObject] firstObject] isKindOfClass:[NSDictionary class]]) return nil;
  return [[[jo firstObject] lastObject] firstObject];
}

- (void)handleHTTPReponse:(NSHTTPURLResponse *)HTTPResponse error:(NSError *)error {
  if (HTTPResponse.statusCode == 200) {
    _backoffSeconds = 0;
    [self connectHelper];
  } else if ([_fatalHTTPStatusCodes containsObject:@(HTTPResponse.statusCode)]) {
    if (self.connectionErrorHandler) self.connectionErrorHandler(HTTPResponse, error);
  } else {
    // If no backoff is set, start out with 5 - 15 seconds.
    // If a backoff is already set, double it, with a max of kBackoffMaxSeconds.
    _backoffSeconds = _backoffSeconds * 2 ?: arc4random_uniform(11) + 5;
    if (_backoffSeconds > _backoffMaxSeconds) _backoffSeconds = _backoffMaxSeconds;
#ifdef DEBUG
    if (error) [self log:[NSString stringWithFormat:@"%@", error]];
#endif
    [self startReachability];
  }
}

#pragma mark NSURLSession block property and methods

/**
 *  MOLAuthenticatingURLSession is the NSURLSessionDelegate. It will call this block every time
 *  the URLSession:task:didCompleteWithError: is called. This allows MOLFCMClient to be notified
 *  when a task ends while using delegate methods.
 */
- (void (^)(NSURLSession *, NSURLSessionDataTask *, NSData *))dataTaskDidReceiveDataBlock {
  __weak __typeof(self) weakSelf = self;
  return ^(NSURLSession *session, NSURLSessionDataTask *dataTask, NSData *data) {
    [weakSelf processMessagesFromData:data];
  };
}

/**
 *  MOLAuthenticatingURLSession is the NSURLSessionDataDelegate. It will call this block every time
 *  the URLSession:dataTask:didReceiveData: is called. This allows for message data chunks to be
 *  processed as they appear in the FCM buffer. For Content-Type: text/html there is a 512 byte
 *  buffer that must be filled before data is returned. Content-Type: application/json does not use
 *  a buffer and data is returned as soon as it is available.
 *
 *  TODO:(bur) Follow up with FCM on Content-Type: application/json. Currently FCM returns data with
 *  Content-Type: text/html. Messages under 512 bytes will not be processed until the connection
 *  drains.
 */
- (void (^)(NSURLSession *, NSURLSessionTask *, NSError *))taskDidCompleteWithErrorBlock {
  __weak __typeof(self) weakSelf = self;
  return ^(NSURLSession *session, NSURLSessionTask *task, NSError *error) {
    __typeof(self) strongSelf = weakSelf;
    // task.response can be nil when an NSURLError* occurs
    if (task.response && ![task.response isKindOfClass:[NSHTTPURLResponse class]]) {
      if (strongSelf.connectionErrorHandler) strongSelf.connectionErrorHandler(nil, error);
      return;
    }
    NSHTTPURLResponse *HTTPResponse = (NSHTTPURLResponse *)task.response;
    [strongSelf handleHTTPReponse:HTTPResponse error:error];
  };
}

#pragma mark log

- (void)log:(NSString *)log {
  if (self.loggingBlock) {
    self.loggingBlock(log);
  }
}

@end
