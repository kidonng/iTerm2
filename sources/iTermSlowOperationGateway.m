//
//  iTermSlowOperationGateway.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 8/12/20.
//

#import "iTermSlowOperationGateway.h"

#import "DebugLogging.h"
#import "iTerm2SharedARC-Swift.h"
#import "iTermAdvancedSettingsModel.h"
#import "ITAddressBookMgr.h"
#import "iTermOpenDirectory.h"
#import "NSStringITerm.h"
#import "ProfileModel.h"
#import "pidinfo.h"
#include <stdatomic.h>

static const char iTermSlowOperationGatewayObserverKey;

typedef void (^iTermRecentBranchFetchCallback)(NSArray<NSString *> *);

@interface iTermGitRecentBranchesBox: NSObject
@property (nonatomic, copy) iTermRecentBranchFetchCallback block;
@end

@implementation iTermGitRecentBranchesBox
- (BOOL)isEqual:(id)object {
    return self == object;
}
@end

@interface iTermGitStateHandlerBox: NSObject
@property (nonatomic, copy) void (^block)(iTermGitState *);
@end

@implementation iTermGitStateHandlerBox

- (BOOL)isEqual:(id)object {
    return self == object;
}
@end

@interface iTermSlowOperationGateway()
@property (nonatomic, readwrite) BOOL ready;
@end

@implementation iTermSlowOperationGateway {
    NSXPCConnection *_connectionToService;
    NSTimeInterval _timeout;
    NSMutableArray<iTermGitStateHandlerBox *> *_gitStateHandlers;
    NSMutableArray<iTermGitRecentBranchesBox *> *_gitRecentBranchFetchCallbacks;
    iTermCPUGovernor *_governor;
}

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    static iTermSlowOperationGateway *instance;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] initPrivate];
    });
    return instance;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _gitStateHandlers = [NSMutableArray array];
        _gitRecentBranchFetchCallbacks = [NSMutableArray array];
        _timeout = 0.5;
        [self connect];
        __weak __typeof(self) weakSelf = self;
        [_connectionToService.remoteObjectProxy handshakeWithReply:^{
            __strong __typeof(self) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            strongSelf.ready = YES;
            [strongSelf startGovernor];
        }];
    }
    return self;
}

- (void)startGovernor {
    if (_governor) {
        _governor.pid = _connectionToService.processIdentifier;
        return;
    }
    _governor = [[iTermCPUGovernor alloc] initWithPID:_connectionToService.processIdentifier
                                            dutyCycle:0.5];
}

- (void)invalidateGovernor {
    [_governor invalidate];
    _governor = nil;
}

- (void)didInvalidateConnection {
    [self invalidateGovernor];
    self.ready = NO;
    [self connect];
}

- (void)connect {
    [_connectionToService removeObserver:self forKeyPath:@"processIdentifier"];
    _connectionToService = [[NSXPCConnection alloc] initWithServiceName:@"com.iterm2.pidinfo"];
    _connectionToService.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(pidinfoProtocol)];
    [_connectionToService resume];
    [_connectionToService addObserver:self
                           forKeyPath:@"processIdentifier"
                              options:0
                              context:(void *)&iTermSlowOperationGatewayObserverKey];

    __weak __typeof(self) weakSelf = self;
    _connectionToService.invalidationHandler = ^{
        // I can't manage to get this called. This project:
        // https://github.com/brenwell/EvenBetterAuthorizationSample
        // originally from:
        // https://developer.apple.com/library/archive/samplecode/EvenBetterAuthorizationSample/Introduction/Intro.html
        // seems to have been written carefully and states that you can retry creating the
        // connection on the main thread.
        DLog(@"Invalidated");
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf didInvalidateConnection];
        });
    };
    _connectionToService.interruptionHandler = ^{
        [weakSelf didInterrupt];
    };
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    if (context != &iTermSlowOperationGatewayObserverKey) {
        return;
    }
    _governor.pid = _connectionToService.processIdentifier;
}

- (void)didInterrupt {
    {
        NSArray<iTermGitStateHandlerBox *> *handlers;
        @synchronized (_gitStateHandlers) {
            handlers = [_gitStateHandlers copy];
            [_gitStateHandlers removeAllObjects];
        }
        DLog(@"didInterrupt. Run all %@ handlers", @(handlers.count));
        [handlers enumerateObjectsUsingBlock:^(iTermGitStateHandlerBox  *_Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            obj.block(nil);
        }];
    }
    {
        NSArray<iTermGitRecentBranchesBox *> *handlers;
        @synchronized (_gitRecentBranchFetchCallbacks) {
            handlers = [_gitRecentBranchFetchCallbacks copy];
            [_gitRecentBranchFetchCallbacks removeAllObjects];
        }
        [handlers enumerateObjectsUsingBlock:^(iTermGitRecentBranchesBox *_Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            obj.block(nil);
        }];
    }
}

- (int)nextReqid {
    static int next;
    @synchronized(self) {
        return next++;
    }
}

- (void)checkIfDirectoryExists:(NSString *)directory
                    completion:(void (^)(BOOL))completion {
    if (!self.ready) {
        return;
    }
    [[_connectionToService remoteObjectProxy] checkIfDirectoryExists:directory
                                                           withReply:^(NSNumber * _Nullable exists) {
        if (!exists) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(exists.boolValue);
        });
    }];
}

- (void)exfiltrateEnvironmentVariableNamed:(NSString *)name
                                     shell:(NSString *)shell
                                completion:(void (^)(NSString * _Nonnull))completion {
    [[_connectionToService remoteObjectProxy] runShellScript:[NSString stringWithFormat:@"echo $%@", name]
                                                       shell:shell
                                                   withReply:^(NSData * _Nullable data,
                                                               NSData * _Nullable error,
                                                               int status) {
        completion(status == 0 ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] stringByTrimmingTrailingCharactersFromCharacterSet:[NSCharacterSet newlineCharacterSet]] : nil);
    }];
}

- (void)asyncGetInfoForProcess:(int)pid
                        flavor:(int)flavor
                           arg:(uint64_t)arg
                    buffersize:(int)buffersize
                         reqid:(int)reqid
                    completion:(void (^)(int rc, NSData *buffer))completion {
    __block atomic_flag finished = ATOMIC_FLAG_INIT;
    [[_connectionToService remoteObjectProxy] getProcessInfoForProcessID:@(pid)
                                                                  flavor:@(flavor)
                                                                     arg:@(arg)
                                                                    size:@(buffersize)
                                                                   reqid:reqid
                                                               withReply:^(NSNumber *rc, NSData *buffer) {
        // Called on a private queue
        if (atomic_flag_test_and_set(&finished)) {
            DLog(@"Return early because already timed out for pid %@", @(pid));
            return;
        }
        DLog(@"Completed with rc=%@", rc);
        if (buffer.length != buffersize) {
            completion(-3, [NSData data]);
            return;
        }
        completion(rc.intValue, buffer);
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (atomic_flag_test_and_set(&finished)) {
            return;
        }
        DLog(@"Timed out");
        completion(-4, [NSData data]);
    });
}

- (void)runCommandInUserShell:(NSString *)command completion:(void (^)(NSString *))completion {
    [[_connectionToService remoteObjectProxy] runShellScript:command
                                                       shell:[iTermOpenDirectory userShell] ?: @"/bin/bash"
                                                   withReply:^(NSData * _Nullable data,
                                                               NSData * _Nullable error,
                                                               int status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(status == 0 ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] stringByTrimmingTrailingCharactersFromCharacterSet:[NSCharacterSet newlineCharacterSet]] : nil);
        });
    }];
}

- (void)findCompletionsWithPrefix:(NSString *)prefix
                    inDirectories:(NSArray<NSString *> *)directories
                              pwd:(NSString *)pwd
                         maxCount:(NSInteger)maxCount
                       executable:(BOOL)executable
                       completion:(void (^)(NSArray<NSString *> *))completions {
    [[_connectionToService remoteObjectProxy] findCompletionsWithPrefix:prefix
                                                          inDirectories:directories
                                                                    pwd:pwd
                                                               maxCount:maxCount
                                                             executable:executable
                                                              withReply:completions];
}

- (void)requestGitStateForPath:(NSString *)path
                    completion:(void (^)(iTermGitState * _Nullable))completion {
    _governor.pid = _connectionToService.processIdentifier;
    iTermGitStateHandlerBox *box = [[iTermGitStateHandlerBox alloc] init];
    box.block = completion;
    @synchronized(_gitStateHandlers) {
        [_gitStateHandlers addObject:box];
    }
    const NSInteger token = [_governor incr];
    [[_connectionToService remoteObjectProxy] requestGitStateForPath:path
                                                             timeout:[iTermAdvancedSettingsModel gitTimeout]
                                                          completion:^(iTermGitState * _Nullable state) {
        [self didGetGitState:state completion:box token:token];
    }];
}

- (void)didGetGitState:(iTermGitState *)gitState completion:(iTermGitStateHandlerBox *)completion token:(NSInteger)token {
    [_governor decr:token];
    @synchronized (_gitStateHandlers) {
        if (![_gitStateHandlers containsObject:completion]) {
            return;
        }
        [_gitStateHandlers removeObject:completion];
    }
    completion.block(gitState);
}

- (void)fetchRecentBranchesAt:(NSString *)path
                        count:(NSInteger)maxCount
                   completion:(void (^)(NSArray<NSString *> *))reply {
    _governor.pid = _connectionToService.processIdentifier;
    const NSInteger token = [_governor incr];
    iTermGitRecentBranchesBox *box = [[iTermGitRecentBranchesBox alloc] init];
    box.block = reply;
    @synchronized(_gitStateHandlers) {
        [_gitRecentBranchFetchCallbacks addObject:box];
    }
    [[_connectionToService remoteObjectProxy] fetchRecentBranchesAt:path
                                                              count:maxCount
                                                         completion:^(NSArray<NSString *> * _Nonnull branches) {
        [self didGetRecentBranches:branches box:box token:token];
    }];
}

- (void)didGetRecentBranches:(NSArray<NSString *> *)branches box:(iTermGitRecentBranchesBox *)box token:(NSInteger)token {
    [_governor decr:token];
    @synchronized (_gitRecentBranchFetchCallbacks) {
        if (![_gitRecentBranchFetchCallbacks containsObject:box]) {
            return;
        }
        [_gitRecentBranchFetchCallbacks removeObject:box];
    }
    box.block(branches);
}
@end
