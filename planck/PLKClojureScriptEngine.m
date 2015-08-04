#import "PLKClojureScriptEngine.h"
#import "ABYUtils.h"
#import "ABYContextManager.h"
#import "PLKBundledOut.h"

@interface PLKClojureScriptEngine()

@property (nonatomic, strong) NSCondition* javaScriptEngineReadyCondition;
@property (nonatomic) BOOL javaScriptEngineReady;
@property (nonatomic, strong) JSContext* context;
@property (nonatomic, strong) ABYContextManager* contextManager;
@property (nonatomic, strong) PLKBundledOut* bundledOut;

@end

@implementation PLKClojureScriptEngine

-(void)initalizeEngineReadyConditionVars
{
    self.javaScriptEngineReadyCondition = [[NSCondition alloc] init];
    self.javaScriptEngineReady = NO;
}

-(void)blockUntilEngineReady
{
    [self.javaScriptEngineReadyCondition lock];
    while (!self.javaScriptEngineReady)
        [self.javaScriptEngineReadyCondition wait];
    
    [self.javaScriptEngineReadyCondition unlock];
}

-(void)signalEngineReady
{
    [self.javaScriptEngineReadyCondition lock];
    self.javaScriptEngineReady = YES;
    [self.javaScriptEngineReadyCondition signal];
    [self.javaScriptEngineReadyCondition unlock];
}

-(void)startInitializationWithSrcPath:(NSString*)srcPath outPath:(NSString*)outPath verbose:(BOOL)verbose
{
    // By default we expect :none, but this can be set if :simple
    
    BOOL useSimpleOutput = NO;
    
    // Initialize out path / URL
    
    NSURL* outURL = [NSURL URLWithString:@"out"];
    
    if (outPath) {
        outURL = [NSURL URLWithString:outPath];
    }
    
    if (outPath) {
        NSFileManager* fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:outURL.path isDirectory:nil]) {
            NSLog(@"ClojureScript compiler output directory not found at \"%@\".", outURL.path);
            NSLog(@"(Current working directory is \"%@\")", [fm currentDirectoryPath]);
            NSLog(@"If running from Xcode, set -o $PROJECT_DIR/planck-cljs/out");
            exit(1);
        }
    }
    
    // ... and prepare for the "bundled" out location

    self.bundledOut = [[PLKBundledOut alloc] init];

    // Now, start initializing JavaScriptCore in a background thread and return
    
    [self initalizeEngineReadyConditionVars];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^() {
        
        self.contextManager = [[ABYContextManager alloc] initWithContext:JSGlobalContextCreate(NULL)
                                                 compilerOutputDirectory:outURL];
        
        [self.contextManager setUpConsoleLog];
        [self.contextManager setupGlobalContext];
        if (!useSimpleOutput) {
            if (outPath) {
                [self.contextManager setUpAmblyImportScript];
            } else {
                [self setUpAmblyImportScriptInContext:self.contextManager.context];
            }
        }
        
        NSString* mainJsFilePath = [[outURL URLByAppendingPathComponent:@"main" isDirectory:NO]
                                    URLByAppendingPathExtension:@"js"].path;
        
        NSURL* googDirectory = [outURL URLByAppendingPathComponent:@"goog"];
        
        if (useSimpleOutput) {
            NSString *mainJsString;
            if (outPath) {
                mainJsString = [NSString stringWithContentsOfFile:mainJsFilePath encoding:NSUTF8StringEncoding error:nil];
            } else {
                mainJsString = [self.bundledOut getSourceForPath:@"main.js"];
            }
            NSAssert(mainJsString != nil, @"The main JavaScript text could not be loaded");
            [ABYUtils evaluateScript:mainJsString inContext:self.contextManager.context];
        } else {
            if (outPath) {
                [self.contextManager bootstrapWithDepsFilePath:mainJsFilePath
                                                  googBasePath:[[googDirectory URLByAppendingPathComponent:@"base" isDirectory:NO] URLByAppendingPathExtension:@"js"].path];
            } else {
                [self bootstrapInContext:self.contextManager.context];
            }
        }
        
        self.context = [JSContext contextWithJSGlobalContextRef:self.contextManager.context];
        
        if (!useSimpleOutput) {
            [self requireAppNamespaces:self.context];
        }
        
        // TODO look into this. Without it thngs won't work.
        [self.context evaluateScript:@"var window = global;"];
        
#ifdef DEBUG
        BOOL debugBuild = YES;
#else
        BOOL debugBuild = NO;
#endif
        
        JSValue* initAppEnvFn = [self getValue:@"init-app-env" inNamespace:@"planck.core" fromContext:self.context];
        [initAppEnvFn callWithArguments:@[@{@"debug-build": @(debugBuild),
                                            @"verbose": @(verbose)}]];
        
        self.context[@"PLANCK_LOAD"] = ^(NSString *path) {
            
            // First try in the srcPath
            
            NSString* fullPath = [NSURL URLWithString:path
                                        relativeToURL:[NSURL URLWithString:srcPath]].path;
            
            NSString* rv = [NSString stringWithContentsOfFile:fullPath
                                                     encoding:NSUTF8StringEncoding error:nil];
            
            // Now try to load the file from the output
            if (!rv) {
                if (outPath) {
                    fullPath = [NSURL URLWithString:path
                                      relativeToURL:[NSURL URLWithString:outPath]].path;
                    rv = [NSString stringWithContentsOfFile:fullPath
                                                   encoding:NSUTF8StringEncoding error:nil];
                } else {
                    rv = [self.bundledOut getSourceForPath:path];
                }
            }
            
            return rv;
        };
        
        self.context[@"PLANCK_READ_FILE"] = ^(NSString *file) {
            return [NSString stringWithContentsOfFile:file
                                             encoding:NSUTF8StringEncoding error:nil];
        };
        
        self.context[@"PLANCK_WRITE_FILE"] = ^(NSString *file, NSString* content) {
            [content writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return @"";
        };
        
        self.context[@"PLANCK_PRINT_FN"] = ^(NSString *message) {
            // supressing
        };
        
        const BOOL isTty = isatty(fileno(stdin));
        
        self.context[@"PLANCK_RAW_READ_STDIN"] = ^NSString*() {
            NSFileHandle *input = [NSFileHandle fileHandleWithStandardInput];
            NSData *inputData = [input readDataOfLength:isTty ? 1 : 1024];
            if (inputData.length) {
                return [[NSString alloc] initWithData:inputData encoding:NSUTF8StringEncoding];
            } else {
                return nil;
            }
        };
        
        self.context[@"PLANCK_RAW_WRITE_STDOUT"] = ^(NSString *s) {
            fprintf(stdout, "%s", [s cStringUsingEncoding:NSUTF8StringEncoding]);
        };
        
        self.context[@"PLANCK_RAW_FLUSH_STDOUT"] = ^() {
            fflush(stdout);
        };
        
        self.context[@"PLANCK_RAW_WRITE_STDERR"] = ^(NSString *s) {
            fprintf(stderr, "%s", [s cStringUsingEncoding:NSUTF8StringEncoding]);
        };
        
        self.context[@"PLANCK_RAW_FLUSH_STDERR"] = ^() {
            fflush(stderr);
        };
        
        self.context[@"PLANCK_PRINT_FN"] = ^(NSString *message) {
            printf("%s", message.UTF8String);
        };
        
        [self setPrintFnsInContext:self.contextManager.context];
        
        // Set up the cljs.user namespace
        
        [self.context evaluateScript:@"goog.provide('cljs.user')"];
        [self.context evaluateScript:@"goog.require('cljs.core')"];
        
        // Go for launch!
        
        [self signalEngineReady];
        
    });
}

-(void)requireAppNamespaces:(JSContext*)context
{
    [context evaluateScript:[NSString stringWithFormat:@"goog.require('%@');", [self munge:@"planck.core"]]];
}

- (JSValue*)getValue:(NSString*)name inNamespace:(NSString*)namespace fromContext:(JSContext*)context
{
    JSValue* namespaceValue = nil;
    for (NSString* namespaceElement in [namespace componentsSeparatedByString: @"."]) {
        if (namespaceValue) {
            namespaceValue = namespaceValue[[self munge:namespaceElement]];
        } else {
            namespaceValue = context[[self munge:namespaceElement]];
        }
    }
    
    return namespaceValue[[self munge:name]];
}

-(NSString*)munge:(NSString*)s
{
    return [[[s stringByReplacingOccurrencesOfString:@"-" withString:@"_"]
             stringByReplacingOccurrencesOfString:@"!" withString:@"_BANG_"]
            stringByReplacingOccurrencesOfString:@"?" withString:@"_QMARK_"];
}

// This implementation is just like Ambly's apart from the canonicalization "goog/../"
// and delegation to CljsRuntime

-(void)setUpAmblyImportScriptInContext:(JSContextRef)context
{
    [ABYUtils installGlobalFunctionWithBlock:
     
     ^JSValueRef(JSContextRef ctx, size_t argc, const JSValueRef argv[]) {
         
         if (argc == 1 && JSValueGetType (ctx, argv[0]) == kJSTypeString)
         {
             JSStringRef pathStrRef = JSValueToStringCopy(ctx, argv[0], NULL);
             NSString* path = (__bridge_transfer NSString *) JSStringCopyCFString( kCFAllocatorDefault, pathStrRef );
             
             JSStringRelease(pathStrRef);
             
             NSString* url = [@"file:///" stringByAppendingString:path];
             
             JSStringRef urlStringRef = JSStringCreateWithCFString((__bridge CFStringRef)url);
             
             if ([path hasPrefix:@"goog/../"]) {
                 path = [path substringFromIndex:8];
             }
             NSError* error = nil;
             NSString* sourceText = [self.bundledOut getSourceForPath:path];
             
             if (!error && sourceText) {
                 
                 JSValueRef jsError = NULL;
                 JSStringRef javaScriptStringRef = JSStringCreateWithCFString((__bridge CFStringRef)sourceText);
                 JSEvaluateScript(ctx, javaScriptStringRef, NULL, urlStringRef, 0, &jsError);
                 JSStringRelease(javaScriptStringRef);
             }
             
             JSStringRelease(urlStringRef);
         }
         
         return JSValueMakeUndefined(ctx);
     }
                                        name:@"AMBLY_IMPORT_SCRIPT"
                                     argList:@"path"
                                   inContext:context];
    
}

// This implementation is just like Ambly's apart from the delegation to CljsRuntime

-(void)bootstrapInContext:(JSContextRef)context
{
    // This implementation mirrors the bootstrapping code that is in -setup
    
    // Setup CLOSURE_IMPORT_SCRIPT
    [ABYUtils evaluateScript:@"CLOSURE_IMPORT_SCRIPT = function(src) { AMBLY_IMPORT_SCRIPT('goog/' + src); return true; }" inContext:context];
    
    // Load goog base
    NSString *baseScriptString = [self.bundledOut getSourceForPath:@"goog/base.js"];
    NSAssert(baseScriptString != nil, @"The goog base JavaScript text could not be loaded");
    [ABYUtils evaluateScript:baseScriptString inContext:context];
    
    // Load the deps file
    NSString *depsScriptString = [self.bundledOut getSourceForPath:@"main.js"];
    NSAssert(depsScriptString != nil, @"The deps JavaScript text could not be loaded");
    [ABYUtils evaluateScript:depsScriptString inContext:context];
    
    [ABYUtils evaluateScript:@"goog.isProvided_ = function(x) { return false; };" inContext:context];
    
    [ABYUtils evaluateScript:@"goog.require = function (name) { return CLOSURE_IMPORT_SCRIPT(goog.dependencies_.nameToPath[name]); };" inContext:context];
    
    [ABYUtils evaluateScript:@"goog.require('cljs.core');" inContext:context];
    
    // redef goog.require to track loaded libs
    [ABYUtils evaluateScript:@"cljs.core._STAR_loaded_libs_STAR_ = cljs.core.into.call(null, cljs.core.PersistentHashSet.EMPTY, [\"cljs.core\"]);\n"
     "goog.require = function (name, reload) {\n"
     "    if(!cljs.core.contains_QMARK_(cljs.core._STAR_loaded_libs_STAR_, name) || reload) {\n"
     "        var AMBLY_TMP = cljs.core.PersistentHashSet.EMPTY;\n"
     "        if (cljs.core._STAR_loaded_libs_STAR_) {\n"
     "            AMBLY_TMP = cljs.core._STAR_loaded_libs_STAR_;\n"
     "        }\n"
     "        cljs.core._STAR_loaded_libs_STAR_ = cljs.core.into.call(null, AMBLY_TMP, [name]);\n"
     "        CLOSURE_IMPORT_SCRIPT(goog.dependencies_.nameToPath[name]);\n"
     "    }\n"
     "};" inContext:context];
}

-(void)setPrintFnsInContext:(JSContextRef)context
{
    [ABYUtils evaluateScript:@"cljs.core.set_print_fn_BANG_.call(null,PLANCK_PRINT_FN);" inContext:context];
    [ABYUtils evaluateScript:@"cljs.core.set_print_err_fn_BANG_.call(null,PLANCK_PRINT_FN);" inContext:context];
}

-(JSValue*)getFunction:(NSString*)name
{
    [self blockUntilEngineReady];
    JSValue* rv = [self getValue:name inNamespace:@"planck.core" fromContext:self.context];
    NSAssert(!rv.isUndefined, name);
    return rv;
}

-(void)executeClojureScript:(NSString*)source expression:(BOOL)expression printNilExpression:(BOOL)printNilExpression;
{
    [[self getFunction:@"read-eval-print"] callWithArguments:@[source, @(expression), @(printNilExpression)]];
}

-(void)runMainInNs:(NSString*)mainNsName args:(NSArray*)args
{
    [[self getFunction:@"run-main"] callWithArguments:@[mainNsName, args]];
}

-(BOOL)isReadable:(NSString*)expression
{
    return [[self getFunction:@"is-readable?"] callWithArguments:@[expression]].toBool;
}

-(NSString*)getCurrentNs
{
    return [[self getFunction:@"get-current-ns"] callWithArguments:@[]].toString;
}

-(NSArray*)getCompletionsForBuffer:(NSString*)buffer
{
    return [[self getFunction:@"get-completions"] callWithArguments:@[buffer]].toArray;
}

@end
