//
//  GZDNSResolver.m
//  Pods
//
//  Created by zhaoy on 21/8/16.
//
//

#import "GZDNSResolver.h"
#import "GZDNSResolverParameter.h"
#import "GZDNSPolicy.h"
#include <arpa/inet.h>
#import <netdb.h>
#include <stdlib.h>

@interface GZDNSResolvingTask : NSObject

@property NSString* hostName;
@property NSError* error;
@property NSMutableArray* ipAddresses;
@property void (^callback)(BOOL isSuccess);

@end

@implementation GZDNSResolvingTask

@end

@interface GZDNSResolver()

// DNS cache table: host name : GZDNSMappingDomain
@property (nonatomic, strong) NSMutableDictionary* dnsCacheTable;

@property (nonatomic, strong) GZDNSPolicy* policy;

// Provide status cache for host name in process of resolving, when user call `resolveHostAndCache`, task will be queued and start async resolving process
@property (nonatomic, strong) NSMutableDictionary* resolvingProcessQueue;

@end

@implementation GZDNSResolver

+ (instancetype)sharedInstance
{
    static GZDNSResolver* resolver;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        resolver = [GZDNSResolver new];
        resolver.dnsCacheTable = [NSMutableDictionary new];
        resolver.resolvingProcessQueue = [NSMutableDictionary new];
    });
    
    return resolver;
}

#pragma mark - initialize & config

/**
 * Load dns configuration from url.
 * url can be either local or a remote address
 */
- (void)loadDNSConfigFromURL:(NSURL*)url
                onCompletion:(void (^)(BOOL isSuccess))callback
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @synchronized (self.dnsCacheTable) {
            
            [_dnsCacheTable removeAllObjects];
            
            NSData *configData = [NSData dataWithContentsOfURL:url];
            if (configData) {
                
                NSError* error = nil;
                NSDictionary* rawDict = [NSJSONSerialization
                                         JSONObjectWithData:configData
                                         options:kNilOptions
                                         error:&error];
                
                if (!rawDict || error) {
                    if (callback) {
                        callback(NO);
                    }
                } else {
                    for (NSString* hostName in [rawDict allKeys]) {
                        
                        GZDNSMappingDomain* domain = [GZDNSMappingDomain buildFromJSON:[rawDict objectForKey:hostName]];
                        if (domain && hostName) {
                            [_dnsCacheTable setObject:domain
                                               forKey:hostName];
                        }
                    }
                    
                    if (callback) {
                        callback(YES);
                    }
                }
                
            } else {
                if (callback) {
                    callback(NO);
                }
            }
        }
    });
}

/**
 *  Config the current dns policy
 */
- (void)updateDNSPolicy:(GZDNSPolicy*)policy
{
    self.policy = policy;
}

#pragma mark - dns management

/**
 *  Update DNS mapping node of url
 */
- (void)updateDNSMapping:(NSString*)ip
                    host:(NSString*)host
{
    
    if (!host.length) {
        return;
    }
    
    const char *utf8 = [ip UTF8String];
    GZDNS_IP_Version version = unset;
    
    // Check valid IPv4.
    struct in_addr dst;
    int success = inet_pton(AF_INET, utf8, &(dst.s_addr));
    if (success != 1) {
        // Check valid IPv6.
        struct in6_addr dst6;
        success = inet_pton(AF_INET6, utf8, &dst6);
        
        if (success) {
            version = ipv_6;
        }
    } else  {
        version = ipv_4;
    }
    
    GZDNSMappingNode* node = [GZDNSMappingNode new];
    node.rawIP = ip;
    node.version = version;
    node.requestFailedCount = 0;
    
    @synchronized (_dnsCacheTable) {
        GZDNSMappingDomain* domain = _dnsCacheTable[host];
        if (!_dnsCacheTable[host]) {
            domain = [GZDNSMappingDomain new];
            domain.hostName = host;
            domain.nodes = [NSMutableArray new];
            [_dnsCacheTable setObject:domain forKey:host];
        }
        
        BOOL needUpdate = YES;
        for (GZDNSMappingNode* existingNode in domain.nodes) {
            if ([node.rawIP isEqualToString:existingNode.rawIP]) {
                needUpdate = NO;
                break;
            }
        }
        
        if (needUpdate) {
            [domain.nodes addObject:node];
        }
    }
}

/**
 *  Invalidate dns mapping by the given ip
 */
- (void)invalidateIP:(NSString*)ip
{
    for (GZDNSMappingDomain* domain in [_dnsCacheTable allValues]) {
        NSMutableArray* tempNodes = [domain.nodes mutableCopy];
        for (GZDNSMappingNode* node in tempNodes) {
            if ([node.rawIP isEqualToString:ip]) {
                @synchronized (_dnsCacheTable) {
                    [domain.nodes removeObject:node];
                }
            }
        }
    }
}

/**
 *  Invalidate dns mapping of a specified hostName
 */
- (void)invalidateDNSOnHost:(NSString*)host
{
    NSMutableArray* tempDomains = [[_dnsCacheTable allValues] mutableCopy];
    for (GZDNSMappingDomain* domain in tempDomains) {
        if ([domain.hostName isEqualToString:host]) {
            @synchronized (_dnsCacheTable) {
                [_dnsCacheTable removeObjectForKey:host];
            }
        }
    }
}

/**
 *  Reset dns mapping
 */
- (void)resetDNSMapping
{
    @synchronized (_dnsCacheTable) {
        [_dnsCacheTable removeAllObjects];
    }
}

#pragma mark - dns resolve

void DNSResolverHostClientCallback ( CFHostRef theHost, CFHostInfoType typeInfo, const CFStreamError *error, void *info) {
    
   dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
       
       // Check host name
       Boolean hasBeenResolved;;
       NSString* hostName = (__bridge NSString*)(CFArrayGetValueAtIndex(CFHostGetNames(theHost, &hasBeenResolved), 0));
       
       // Resolving array
       GZDNSResolver* resolver = (__bridge GZDNSResolver*)info;
       GZDNSResolvingTask* resolvingTask = resolver.resolvingProcessQueue[hostName];
       
       if (error->error) {
           resolvingTask.error = [NSError errorWithDomain:@"resolving error"
                                                     code:error->error
                                                 userInfo:nil];
           dispatch_async(dispatch_get_main_queue(), ^{
               if (resolvingTask.callback) {
                   resolvingTask.callback(NO);
               }
           });
           return;
       }
       
       if (hasBeenResolved) {
          
           // Listing address array
           CFArrayRef addressArray = CFHostGetAddressing(theHost, NULL);
           resolvingTask.ipAddresses = [(__bridge NSArray*)addressArray copy];
           
           // Update resolving task to DNS cache table
           for (NSData* address in resolvingTask.ipAddresses) {
               
               int         err;
               char        addrStr[NI_MAXHOST];
               
               assert([address isKindOfClass:[NSData class]]);
               
               err = getnameinfo((const struct sockaddr *) [address bytes], (socklen_t) [address length], addrStr, sizeof(addrStr), NULL, 0, NI_NUMERICHOST);
               if (err == 0) {

                   NSString* ipString = [NSString stringWithUTF8String:addrStr];
                   [resolver updateDNSMapping:hostName
                                         host:ipString];
                   
               } else {
                   break;
               }
           }
           
           dispatch_async(dispatch_get_main_queue(), ^{
               if (resolvingTask.callback) {
                   resolvingTask.callback(YES);
               }
           });
       } else {
           dispatch_async(dispatch_get_main_queue(), ^{
               if (resolvingTask.callback) {
                   resolvingTask.callback(NO);
               }
           });
       }
   });
}

- (void)resolveHostAndCache:(NSString*)hostName withCompletionCall:(void (^)(BOOL isSuccess))callback
{
    // Param check
    if (!hostName.length) {
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (callback) {
                callback(NO);
            }
        });
        
        return;
    }
    
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        CFHostRef host = CFHostCreateWithName(kCFAllocatorDefault , (__bridge  CFStringRef)(hostName));
        CFHostClientContext ctx = {.info = (__bridge void*)self};
        CFHostSetClient(host ,DNSResolverHostClientCallback, &ctx);
        CFRunLoopRef runloop = CFRunLoopGetCurrent();
        CFHostScheduleWithRunLoop(host, runloop, CFSTR("DNSResolverRunLoopMode"));
        
        // start the name resolution
        CFStreamError error;
        Boolean didStart = CFHostStartInfoResolution(host, kCFHostAddresses, &error);
        if (!didStart) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (callback) {
                    callback(NO);
                }
            });
            return;
        }
        
        GZDNSResolvingTask* resolvingTask = [GZDNSResolvingTask new];
        resolvingTask.hostName = hostName;
        resolvingTask.callback = callback;
        
        [self.resolvingProcessQueue setObject:resolvingTask forKey:hostName];
        
        // run the run loop for 50ms at a time, always checking if we should cancel
        while(!resolvingTask.error && !resolvingTask.ipAddresses) {
            CFRunLoopRunInMode(CFSTR("DNSResolverRunLoopMode"), 0.05, true);
        }

        CFHostUnscheduleFromRunLoop(host, runloop, CFSTR("DNSResolverRunLoopMode"));
        CFHostSetClient(host, NULL, NULL);
        CFRelease(host);
    });
}

- (NSString*)resolveIPFromURL:(NSURL*)originalURL
{
    // Input check
    if (!originalURL.host) {
        return originalURL.host;
    }
    
    // Based on DNS strategy filter out corresponding IP
    NSMutableArray* candidateIPs = [NSMutableArray new];
    GZDNSMappingDomain* domain = _dnsCacheTable[originalURL.host];
    if (!domain) {
        return originalURL.host;
    }
    
    candidateIPs = [domain.nodes mutableCopy];
    
    // Filter by locale information
    if (self.policy.dnsResolveStrategy & checkLocale) {
        NSLocale *currentLocale = [NSLocale currentLocale];
        NSString *countryCode = [currentLocale objectForKey:NSLocaleCountryCode];
        
        for (GZDNSMappingNode* node in domain.nodes) {
            if (![node.locale isEqualToString:countryCode]) {
                [candidateIPs removeObject:node];
            }
        }
    }
    
    // Filter by IPV information
    if (self.policy.dnsResolveStrategy & checkIPV) {
        
        for (GZDNSMappingNode* node in domain.nodes) {
            if (node.version != self.policy.dominatingIPProtocol) {
                [candidateIPs removeObject:node];
            }
        }
    }
    
    // Empty remaining check
    if (!candidateIPs.count) {
        return originalURL.host;
    }
    
    // Filter by failureCount information
    if (self.policy.dnsResolveStrategy & checkSuccessRate) {
        [candidateIPs sortUsingComparator:^NSComparisonResult(id  _Nonnull obj1, id  _Nonnull obj2) {
            return [@(((GZDNSMappingNode*)obj1).requestFailedCount) compare:@(((GZDNSMappingNode*)obj2).requestFailedCount)];
        }];
    }
    
    // Make random pick from array
    int index = arc4random_uniform(candidateIPs.count);
    return ((GZDNSMappingNode*)[candidateIPs objectAtIndex:index]).rawIP;}


@end
