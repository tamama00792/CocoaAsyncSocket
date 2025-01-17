//
//  GCDAsyncSocket.m
//  
//  This class is in the public domain.
//  Originally created by Robbie Hanson in Q4 2010.
//  Updated and maintained by Deusty LLC and the Apple development community.
//
//  https://github.com/robbiehanson/CocoaAsyncSocket
//

#import "GCDAsyncSocket.h"

#if TARGET_OS_IPHONE
#import <CFNetwork/CFNetwork.h>
#endif

#import <TargetConditionals.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <netdb.h>
#import <netinet/in.h>
#import <net/if.h>
#import <sys/socket.h>
#import <sys/types.h>
#import <sys/ioctl.h>
#import <sys/poll.h>
#import <sys/uio.h>
#import <sys/un.h>
#import <unistd.h>

// 判定不是arc则警告
#if ! __has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag (or convert project to ARC).
// For more information see: https://github.com/robbiehanson/CocoaAsyncSocket/wiki/ARC
#endif

// 默认关闭日志
#ifndef GCDAsyncSocketLoggingEnabled
#define GCDAsyncSocketLoggingEnabled 0
#endif

#if GCDAsyncSocketLoggingEnabled

// Logging Enabled - See log level below

// Logging uses the CocoaLumberjack framework (which is also GCD based).
// https://github.com/robbiehanson/CocoaLumberjack
// 
// It allows us to do a lot of logging without significantly slowing down the code.
#import "DDLog.h"

#define LogAsync   YES
#define LogContext GCDAsyncSocketLoggingContext

#define LogObjc(flg, frmt, ...) LOG_OBJC_MAYBE(LogAsync, logLevel, flg, LogContext, frmt, ##__VA_ARGS__)
#define LogC(flg, frmt, ...)    LOG_C_MAYBE(LogAsync, logLevel, flg, LogContext, frmt, ##__VA_ARGS__)

#define LogError(frmt, ...)     LogObjc(LOG_FLAG_ERROR,   (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)
#define LogWarn(frmt, ...)      LogObjc(LOG_FLAG_WARN,    (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)
#define LogInfo(frmt, ...)      LogObjc(LOG_FLAG_INFO,    (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)
#define LogVerbose(frmt, ...)   LogObjc(LOG_FLAG_VERBOSE, (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)

#define LogCError(frmt, ...)    LogC(LOG_FLAG_ERROR,   (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)
#define LogCWarn(frmt, ...)     LogC(LOG_FLAG_WARN,    (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)
#define LogCInfo(frmt, ...)     LogC(LOG_FLAG_INFO,    (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)
#define LogCVerbose(frmt, ...)  LogC(LOG_FLAG_VERBOSE, (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)

#define LogTrace()              LogObjc(LOG_FLAG_VERBOSE, @"%@: %@", THIS_FILE, THIS_METHOD)
#define LogCTrace()             LogC(LOG_FLAG_VERBOSE, @"%@: %s", THIS_FILE, __FUNCTION__)

#ifndef GCDAsyncSocketLogLevel
#define GCDAsyncSocketLogLevel LOG_LEVEL_VERBOSE
#endif

// Log levels : off, error, warn, info, verbose
static const int logLevel = GCDAsyncSocketLogLevel;

#else

// Logging Disabled

#define LogError(frmt, ...)     {}
#define LogWarn(frmt, ...)      {}
#define LogInfo(frmt, ...)      {}
#define LogVerbose(frmt, ...)   {}

#define LogCError(frmt, ...)    {}
#define LogCWarn(frmt, ...)     {}
#define LogCInfo(frmt, ...)     {}
#define LogCVerbose(frmt, ...)  {}

#define LogTrace()              {}
#define LogCTrace(frmt, ...)    {}

#endif

/**
 * Seeing a return statements within an inner block
 * can sometimes be mistaken for a return point of the enclosing method.
 * This makes inline blocks a bit easier to read.
**/
// 为了代码可读性，指明是block中的return
#define return_from_block  return

/**
 * A socket file descriptor is really just an integer.
 * It represents the index of the socket within the kernel.
 * This makes invalid file descriptor comparisons easier to read.
**/
// socket文件描述符本身就是个整型数，表示socket在kernel中的索引。这里用来表示非法的文件描述符
#define SOCKET_NULL -1


NSString *const GCDAsyncSocketException = @"GCDAsyncSocketException";
NSString *const GCDAsyncSocketErrorDomain = @"GCDAsyncSocketErrorDomain";

NSString *const GCDAsyncSocketQueueName = @"GCDAsyncSocket";
NSString *const GCDAsyncSocketThreadName = @"GCDAsyncSocket-CFStream";

NSString *const GCDAsyncSocketManuallyEvaluateTrust = @"GCDAsyncSocketManuallyEvaluateTrust";
#if TARGET_OS_IPHONE
NSString *const GCDAsyncSocketUseCFStreamForTLS = @"GCDAsyncSocketUseCFStreamForTLS";
#endif
NSString *const GCDAsyncSocketSSLPeerID = @"GCDAsyncSocketSSLPeerID";
NSString *const GCDAsyncSocketSSLProtocolVersionMin = @"GCDAsyncSocketSSLProtocolVersionMin";
NSString *const GCDAsyncSocketSSLProtocolVersionMax = @"GCDAsyncSocketSSLProtocolVersionMax";
NSString *const GCDAsyncSocketSSLSessionOptionFalseStart = @"GCDAsyncSocketSSLSessionOptionFalseStart";
NSString *const GCDAsyncSocketSSLSessionOptionSendOneByteRecord = @"GCDAsyncSocketSSLSessionOptionSendOneByteRecord";
NSString *const GCDAsyncSocketSSLCipherSuites = @"GCDAsyncSocketSSLCipherSuites";
NSString *const GCDAsyncSocketSSLALPN = @"GCDAsyncSocketSSLALPN";
#if !TARGET_OS_IPHONE
NSString *const GCDAsyncSocketSSLDiffieHellmanParameters = @"GCDAsyncSocketSSLDiffieHellmanParameters";
#endif

// 标识socket的一些配置和状态
enum GCDAsyncSocketFlags
{
// socket开始，可能在等待接收连接中或者在连接远端中
	kSocketStarted                 = 1 <<  0,  // If set, socket has been started (accepting/connecting)
	// socket连接建立成功
	kConnected                     = 1 <<  1,  // If set, the socket is connected
	// 不允许读和写
	kForbidReadsWrites             = 1 <<  2,  // If set, no new reads or writes are allowed
	// 由于可能超时，读操作被暂停
	kReadsPaused                   = 1 <<  3,  // If set, reads are paused due to possible timeout
	// 由于可能超时，写操作被暂停
	kWritesPaused                  = 1 <<  4,  // If set, writes are paused due to possible timeout
	// 在读队列清空后才断开连接
	kDisconnectAfterReads          = 1 <<  5,  // If set, disconnect after no more reads are queued
	// 在写队列清空后才断开连接
	kDisconnectAfterWrites         = 1 <<  6,  // If set, disconnect after no more writes are queued
	// 表示socket能接收字节
	kSocketCanAcceptBytes          = 1 <<  7,  // If set, we know socket can accept bytes. If unset, it's unknown.
	// 表示读源被暂停了
	kReadSourceSuspended           = 1 <<  8,  // If set, the read source is suspended
	// 表示写源被暂停了
	kWriteSourceSuspended          = 1 <<  9,  // If set, the write source is suspended
	// 表示升级到TLS
	kQueuedTLS                     = 1 << 10,  // If set, we've queued an upgrade to TLS
	// 表示正在等待TLS协商完成
	kStartingReadTLS               = 1 << 11,  // If set, we're waiting for TLS negotiation to complete
	// 表示正在等待TLS协商完成
	kStartingWriteTLS              = 1 << 12,  // If set, we're waiting for TLS negotiation to complete
	// 表示正在使用SSL/TLS加密通信
	kSocketSecure                  = 1 << 13,  // If set, socket is using secure communication via SSL/TLS
	// 表示从socket读到了文件终止符
	kSocketHasReadEOF              = 1 << 14,  // If set, we have read EOF from socket
	// 表示读到了文件终止符且预缓冲区已经都读取完了
	kReadStreamClosed              = 1 << 15,  // If set, we've read EOF plus prebuffer has been drained
	// 表示socket正在被销毁
	kDealloc                       = 1 << 16,  // If set, the socket is being deallocated
#if TARGET_OS_IPHONE
// 表示流已经被加到了监听线程
	kAddedStreamsToRunLoop         = 1 << 17,  // If set, CFStreams have been added to listener thread
	// 表示强制使用CFStream来代替加密传输
	kUsingCFStreamForTLS           = 1 << 18,  // If set, we're forced to use CFStream instead of SecureTransport
	// 表示读流提示有字节可用
	kSecureSocketHasBytesAvailable = 1 << 19,  // If set, CFReadStream has notified us of bytes available
#endif
};
// socket设置
enum GCDAsyncSocketConfig
{
// 不允许IPv4
	kIPv4Disabled              = 1 << 0,  // If set, IPv4 is disabled
	// 不允许IPv6
	kIPv6Disabled              = 1 << 1,  // If set, IPv6 is disabled
	// 优先用IPv6
	kPreferIPv6                = 1 << 2,  // If set, IPv6 is preferred over IPv4
	// 如果设置，socket会保持打开，哪怕读流关闭
	kAllowHalfDuplexConnection = 1 << 3,  // If set, the socket will stay open even if the read stream closes
};

// CFStream使用的属性
#if TARGET_OS_IPHONE
  static NSThread *cfstreamThread;  // Used for CFStreams


  static uint64_t cfstreamThreadRetainCount;   // setup & teardown
  static dispatch_queue_t cfstreamThreadSetupQueue; // setup & teardown
#endif

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * A PreBuffer is used when there is more data available on the socket
 * than is being requested by current read request.
 * In this case we slurp up all data from the socket (to minimize sys calls),
 * and store additional yet unread data in a "prebuffer".
 * 
 * The prebuffer is entirely drained before we read from the socket again.
 * In other words, a large chunk of data is written is written to the prebuffer.
 * The prebuffer is then drained via a series of one or more reads (for subsequent read request(s)).
 * 
 * A ring buffer was once used for this purpose.
 * But a ring buffer takes up twice as much memory as needed (double the size for mirroring).
 * In fact, it generally takes up more than twice the needed size as everything has to be rounded up to vm_page_size.
 * And since the prebuffer is always completely drained after being written to, a full ring buffer isn't needed.
 * 
 * The current design is very simple and straight-forward, while also keeping memory requirements lower.
**/
// 预缓冲区对象，每次从socket取出全部数据呀，然后一次次读，从而避免多次的系统调用
@interface GCDAsyncSocketPreBuffer : NSObject
{
	uint8_t *preBuffer;// 缓冲区
	size_t preBufferSize;// 缓冲区大小
	
	uint8_t *readPointer;// 读指针
	uint8_t *writePointer;// 写指针
}
// 根据大小初始化
- (instancetype)initWithCapacity:(size_t)numBytes NS_DESIGNATED_INITIALIZER;
// 确保写区大小
- (void)ensureCapacityForWrite:(size_t)numBytes;
// 可用字节
- (size_t)availableBytes;
// 读缓存
- (uint8_t *)readBuffer;
// 获取读指针和可读大小
- (void)getReadBuffer:(uint8_t **)bufferPtr availableBytes:(size_t *)availableBytesPtr;
// 获取可写大小
- (size_t)availableSpace;
// 获取写指针
- (uint8_t *)writeBuffer;
// 获取写指针和可写大小
- (void)getWriteBuffer:(uint8_t **)bufferPtr availableSpace:(size_t *)availableSpacePtr;
// 移动读指针
- (void)didRead:(size_t)bytesRead;
// 移动写指针
- (void)didWrite:(size_t)bytesWritten;
// 重置读写指针
- (void)reset;

@end

@implementation GCDAsyncSocketPreBuffer

// Cover the superclass' designated initializer
- (instancetype)init NS_UNAVAILABLE
{
	NSAssert(0, @"Use the designated initializer");
	return nil;
}
// 根据大小为缓冲区分配内存，并设置读写指针
- (instancetype)initWithCapacity:(size_t)numBytes
{
	if ((self = [super init]))
	{
		preBufferSize = numBytes;
		preBuffer = malloc(preBufferSize);
		
		readPointer = preBuffer;
		writePointer = preBuffer;
	}
	return self;
}
// 释放缓冲区内存
- (void)dealloc
{
	if (preBuffer)
		free(preBuffer);
}
// 确保剩余可写空间的大小
- (void)ensureCapacityForWrite:(size_t)numBytes
{
// 获取可用空间
	size_t availableSpace = [self availableSpace];
	// 如果需要确保的大小大于可用空间，则在原地址的基础上扩大一段新的空间（realloc），并根据原先的读写offset重新设置读写指针的位置
	if (numBytes > availableSpace)
	{
		size_t additionalBytes = numBytes - availableSpace;
		
		size_t newPreBufferSize = preBufferSize + additionalBytes;
		uint8_t *newPreBuffer = realloc(preBuffer, newPreBufferSize);
		
		size_t readPointerOffset = readPointer - preBuffer;
		size_t writePointerOffset = writePointer - preBuffer;
		
		preBuffer = newPreBuffer;
		preBufferSize = newPreBufferSize;
		
		readPointer = preBuffer + readPointerOffset;
		writePointer = preBuffer + writePointerOffset;
	}
}
// 可读字节=写指针-读指针
- (size_t)availableBytes
{
	return writePointer - readPointer;
}
// 获取读指针
- (uint8_t *)readBuffer
{
	return readPointer;
}
// 获取读指针和可读字节
- (void)getReadBuffer:(uint8_t **)bufferPtr availableBytes:(size_t *)availableBytesPtr
{
	if (bufferPtr) *bufferPtr = readPointer;
	if (availableBytesPtr) *availableBytesPtr = [self availableBytes];
}
// 移动读指针，如果与写指针相遇，则说明缓冲区读完，重置读写指针
- (void)didRead:(size_t)bytesRead
{
	readPointer += bytesRead;
	
	if (readPointer == writePointer)
	{
		// The prebuffer has been drained. Reset pointers.
		readPointer  = preBuffer;
		writePointer = preBuffer;
	}
}
// 可用空间=总大小-写指针大小
- (size_t)availableSpace
{
	return preBufferSize - (writePointer - preBuffer);
}
// 获取写指针
- (uint8_t *)writeBuffer
{
	return writePointer;
}
// 获取写指针和可写空间大小
- (void)getWriteBuffer:(uint8_t **)bufferPtr availableSpace:(size_t *)availableSpacePtr
{
	if (bufferPtr) *bufferPtr = writePointer;
	if (availableSpacePtr) *availableSpacePtr = [self availableSpace];
}
// 移动写指针
- (void)	didWrite:(size_t)bytesWritten
{
	writePointer += bytesWritten;
}
// 重置读写指针
- (void)reset
{
	readPointer  = preBuffer;
	writePointer = preBuffer;
}

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * The GCDAsyncReadPacket encompasses the instructions for any given read.
 * The content of a read packet allows the code to determine if we're:
 *  - reading to a certain length
 *  - reading to a certain separator
 *  - or simply reading the first chunk of available data
**/
// 包含了一系列读指令的对象
@interface GCDAsyncReadPacket : NSObject
{
  @public
	NSMutableData *buffer;// 数据的指针
	NSUInteger startOffset;// 起始点偏移量
	NSUInteger bytesDone;// 读完的字节数
	NSUInteger maxLength;// 最大长度
	NSTimeInterval timeout;// 超时时长
	NSUInteger readLength;// 读取的长度
	NSData *term;// 终结符
	BOOL bufferOwner;
	NSUInteger originalBufferLength;
	long tag;
}
// 初始化方法
- (instancetype)initWithData:(NSMutableData *)d
                 startOffset:(NSUInteger)s
                   maxLength:(NSUInteger)m
                     timeout:(NSTimeInterval)t
                  readLength:(NSUInteger)l
                  terminator:(NSData *)e
                         tag:(long)i NS_DESIGNATED_INITIALIZER;
// 确保额外数据长度
- (void)ensureCapacityForAdditionalDataOfLength:(NSUInteger)bytesToRead;
// 传入一个默认的读取长度，获取最优的读取长度，并通过指针返回是否需要预缓冲区
- (NSUInteger)optimalReadLengthWithDefault:(NSUInteger)defaultValue shouldPreBuffer:(BOOL *)shouldPreBufferPtr;
// 针对没有终止符的数据计算出合适的读取长度
- (NSUInteger)readLengthForNonTermWithHint:(NSUInteger)bytesAvailable;
// 针对带有终结符的数据计算出最合适的读取长度，并返回是否需要预缓冲区
- (NSUInteger)readLengthForTermWithHint:(NSUInteger)bytesAvailable shouldPreBuffer:(BOOL *)shouldPreBufferPtr;
// 算出从预缓冲区读取的数据长度，不超过最大长度，读到指定的终止符也会停止读取
- (NSUInteger)readLengthForTermWithPreBuffer:(GCDAsyncSocketPreBuffer *)preBuffer found:(BOOL *)foundPtr;
// 在预缓冲区指定numBytes后寻找终结符，并将超出终结符的长度返回
- (NSInteger)searchForTermAfterPreBuffering:(ssize_t)numBytes;

@end

@implementation GCDAsyncReadPacket

// Cover the superclass' designated initializer
// 初始化方法（废弃）
- (instancetype)init NS_UNAVAILABLE
{
	NSAssert(0, @"Use the designated initializer");
	return nil;
}
// 初始化方法，创建或持有一个存储读入数据的data
- (instancetype)initWithData:(NSMutableData *)d
                 startOffset:(NSUInteger)s
                   maxLength:(NSUInteger)m
                     timeout:(NSTimeInterval)t
                  readLength:(NSUInteger)l
                  terminator:(NSData *)e
                         tag:(long)i
{
	if((self = [super init]))
	{
		bytesDone = 0;
		maxLength = m;
		timeout = t;
		readLength = l;
		term = [e copy];
		tag = i;
		// 如果有data，则根据传入的参数设置成员变量
		if (d)
		{
			buffer = d;
			startOffset = s;
			bufferOwner = NO;
			originalBufferLength = [d length];
		}		
		else
		{
		// 如果没data，则根据readlength的值创建一段对应长度的data
			if (readLength > 0)
				buffer = [[NSMutableData alloc] initWithLength:readLength];
			else
			// 如果readlength长度不大于0，则创建一段长度为0的data，并设置bufferOwner为yes
				buffer = [[NSMutableData alloc] initWithLength:0];
			
			startOffset = 0;
			bufferOwner = YES;
			originalBufferLength = 0;
		}
	}
	return self;
}

/**
 * Increases the length of the buffer (if needed) to ensure a read of the given size will fit.
**/
// 确保data拥有足够的长度来继续写入对应的数据，如果不够则扩大
- (void)ensureCapacityForAdditionalDataOfLength:(NSUInteger)bytesToRead
{
	NSUInteger buffSize = [buffer length];
	NSUInteger buffUsed = startOffset + bytesDone;
	// 算出buffer的剩余空间
	NSUInteger buffSpace = buffSize - buffUsed;
	
	if (bytesToRead > buffSpace)
	{
	// 如果空间不够则扩充
		NSUInteger buffInc = bytesToRead - buffSpace;
		
		[buffer increaseLengthBy:buffInc];
	}
}

/**
 * This method is used when we do NOT know how much data is available to be read from the socket.
 * This method returns the default value unless it exceeds the specified readLength or maxLength.
 * 
 * Furthermore, the shouldPreBuffer decision is based upon the packet type,
 * and whether the returned value would fit in the current buffer without requiring a resize of the buffer.
**/
// 返回最合适的读取长度，并返回是否需要使用预缓冲区
- (NSUInteger)optimalReadLengthWithDefault:(NSUInteger)defaultValue shouldPreBuffer:(BOOL *)shouldPreBufferPtr
{
	NSUInteger result;
	
	if (readLength > 0)
	{
		// Read a specific length of data
		// 如果读取长度有值，则算出剩余长度作为结果
		result = readLength - bytesDone;
		
		// There is no need to prebuffer since we know exactly how much data we need to read.
		// Even if the buffer isn't currently big enough to fit this amount of data,
		// it would have to be resized eventually anyway.
		// 设置不需要预缓冲区，因为已经知道确切的总数据长度，即使缓冲区大小不够，后续也会有合适的时机去扩充
		if (shouldPreBufferPtr)
			*shouldPreBufferPtr = NO;
	}
	else
	{
		// Either reading until we find a specified terminator,
		// or we're simply reading all available data.
		// 
		// In other words, one of:
		// 
		// - readDataToData packet
		// - readDataWithTimeout packet
		// 如果读取长度没有值
		if (maxLength > 0)
		// 如果有最大长度，则根据最大长度算出剩余长度
			result =  MIN(defaultValue, (maxLength - bytesDone));
		else
		// 如果也没有最大长度，则取传入的默认长度
			result = defaultValue;
		
		// Since we don't know the size of the read in advance,
		// the shouldPreBuffer decision is based upon whether the returned value would fit
		// in the current buffer without requiring a resize of the buffer.
		// 
		// This is because, in all likelyhood, the amount read from the socket will be less than the default value.
		// Thus we should avoid over-allocating the read buffer when we can simply use the pre-buffer instead.
		if (shouldPreBufferPtr)
		{
		// 如果现在的缓冲区大小已经满足容纳接下来要读取的数据长度，则不需要预缓冲区，否则需要
			NSUInteger buffSize = [buffer length];
			NSUInteger buffUsed = startOffset + bytesDone;
			
			NSUInteger buffSpace = buffSize - buffUsed;
			
			if (buffSpace >= result)
				*shouldPreBufferPtr = NO;
			else
				*shouldPreBufferPtr = YES;
		}
	}
	
	return result;
}

/**
 * For read packets without a set terminator, returns the amount of data
 * that can be read without exceeding the readLength or maxLength.
 * 
 * The given parameter indicates the number of bytes estimated to be available on the socket,
 * which is taken into consideration during the calculation.
 * 
 * The given hint MUST be greater than zero.
**/
// 针对没有终止符的数据计算出合适的读取长度
- (NSUInteger)readLengthForNonTermWithHint:(NSUInteger)bytesAvailable
{
	NSAssert(term == nil, @"This method does not apply to term reads");
	NSAssert(bytesAvailable > 0, @"Invalid parameter: bytesAvailable");
	
	if (readLength > 0)
	{
		// Read a specific length of data
		// 如果有读取长度，则根据剩余长度和预估的数据长度取个最小值
		return MIN(bytesAvailable, (readLength - bytesDone));
		
		// No need to avoid resizing the buffer.
		// If the user provided their own buffer,
		// and told us to read a certain length of data that exceeds the size of the buffer,
		// then it is clear that our code will resize the buffer during the read operation.
		// 
		// This method does not actually do any resizing.
		// The resizing will happen elsewhere if needed.
	}
	else
	{
		// Read all available data
		NSUInteger result = bytesAvailable;
		// 如果有最大长度，则取剩余长度和预估长度的最小值，否则直接取预估长度
		if (maxLength > 0)
		{
			result = MIN(result, (maxLength - bytesDone));
		}
		
		// No need to avoid resizing the buffer.
		// If the user provided their own buffer,
		// and told us to read all available data without giving us a maxLength,
		// then it is clear that our code might resize the buffer during the read operation.
		// 
		// This method does not actually do any resizing.
		// The resizing will happen elsewhere if needed.
		
		return result;
	}
}

/**
 * For read packets with a set terminator, returns the amount of data
 * that can be read without exceeding the maxLength.
 * 
 * The given parameter indicates the number of bytes estimated to be available on the socket,
 * which is taken into consideration during the calculation.
 * 
 * To optimize memory allocations, mem copies, and mem moves
 * the shouldPreBuffer boolean value will indicate if the data should be read into a prebuffer first,
 * or if the data can be read directly into the read packet's buffer.
**/
// 针对带有终结符的数据计算出最合适的读取长度，并返回是否需要预缓冲区
- (NSUInteger)readLengthForTermWithHint:(NSUInteger)bytesAvailable shouldPreBuffer:(BOOL *)shouldPreBufferPtr
{
	NSAssert(term != nil, @"This method does not apply to non-term reads");
	NSAssert(bytesAvailable > 0, @"Invalid parameter: bytesAvailable");
	
	
	NSUInteger result = bytesAvailable;
	// 如果有最大长度，则取剩余长度和预估长度的最小值
	if (maxLength > 0)
	{
		result = MIN(result, (maxLength - bytesDone));
	}
	
	// Should the data be read into the read packet's buffer, or into a pre-buffer first?
	// 
	// One would imagine the preferred option is the faster one.
	// So which one is faster?
	// 
	// Reading directly into the packet's buffer requires:
	// 1. Possibly resizing packet buffer (malloc/realloc)
	// 2. Filling buffer (read)
	// 3. Searching for term (memcmp)
	// 4. Possibly copying overflow into prebuffer (malloc/realloc, memcpy)
	// 
	// Reading into prebuffer first:
	// 1. Possibly resizing prebuffer (malloc/realloc)
	// 2. Filling buffer (read)
	// 3. Searching for term (memcmp)
	// 4. Copying underflow into packet buffer (malloc/realloc, memcpy)
	// 5. Removing underflow from prebuffer (memmove)
	// 
	// Comparing the performance of the two we can see that reading
	// data into the prebuffer first is slower due to the extra memove.
	// 
	// However:
	// The implementation of NSMutableData is open source via core foundation's CFMutableData.
	// Decreasing the length of a mutable data object doesn't cause a realloc.
	// In other words, the capacity of a mutable data object can grow, but doesn't shrink.
	// 
	// This means the prebuffer will rarely need a realloc.
	// The packet buffer, on the other hand, may often need a realloc.
	// This is especially true if we are the buffer owner.
	// Furthermore, if we are constantly realloc'ing the packet buffer,
	// and then moving the overflow into the prebuffer,
	// then we're consistently over-allocating memory for each term read.
	// And now we get into a bit of a tradeoff between speed and memory utilization.
	// 
	// The end result is that the two perform very similarly.
	// And we can answer the original question very simply by another means.
	// 
	// If we can read all the data directly into the packet's buffer without resizing it first,
	// then we do so. Otherwise we use the prebuffer.
	// 如果剩余空间比读的数据大，则不使用预缓冲区，否则使用
	if (shouldPreBufferPtr)
	{
		NSUInteger buffSize = [buffer length];
		NSUInteger buffUsed = startOffset + bytesDone;
		
		if ((buffSize - buffUsed) >= result)
			*shouldPreBufferPtr = NO;
		else
			*shouldPreBufferPtr = YES;
	}
	
	return result;
}

/**
 * For read packets with a set terminator,
 * returns the amount of data that can be read from the given preBuffer,
 * without going over a terminator or the maxLength.
 * 
 * It is assumed the terminator has not already been read.
**/
// 算出从预缓冲区读取的数据长度，不超过最大长度，读到指定的终止符也会停止读取
- (NSUInteger)readLengthForTermWithPreBuffer:(GCDAsyncSocketPreBuffer *)preBuffer found:(BOOL *)foundPtr
{
	NSAssert(term != nil, @"This method does not apply to non-term reads");
	NSAssert([preBuffer availableBytes] > 0, @"Invoked with empty pre buffer!");
	
	// We know that the terminator, as a whole, doesn't exist in our own buffer.
	// But it is possible that a _portion_ of it exists in our buffer.
	// So we're going to look for the terminator starting with a portion of our own buffer.
	// 
	// Example:
	// 
	// term length      = 3 bytes
	// bytesDone        = 5 bytes
	// preBuffer length = 5 bytes
	// 
	// If we append the preBuffer to our buffer,
	// it would look like this:
	// 
	// ---------------------
	// |B|B|B|B|B|P|P|P|P|P|
	// ---------------------
	// 
	// So we start our search here:
	// 
	// ---------------------
	// |B|B|B|B|B|P|P|P|P|P|
	// -------^-^-^---------
	// 
	// And move forwards...
	// 
	// ---------------------
	// |B|B|B|B|B|P|P|P|P|P|
	// ---------^-^-^-------
	// 
	// Until we find the terminator or reach the end.
	// 
	// ---------------------
	// |B|B|B|B|B|P|P|P|P|P|
	// ---------------^-^-^-
	
	BOOL found = NO;
	
	NSUInteger termLength = [term length];
	NSUInteger preBufferLength = [preBuffer availableBytes];
	
	if ((bytesDone + preBufferLength) < termLength)
	{
	// 如果已经读取的部分加上预缓冲区剩余的部分总长度还比终止符短，那么就返回预缓冲区剩余的长度，因为此时不会存在终止符
		// Not enough data for a full term sequence yet
		return preBufferLength;
	}
	
	NSUInteger maxPreBufferLength;
	if (maxLength > 0) {
	// 如果最大长度有值，那么算出最大的预缓冲长度为剩余长度与预缓冲区可用长度的最小值
		maxPreBufferLength = MIN(preBufferLength, (maxLength - bytesDone));
		
		// Note: maxLength >= termLength
	}
	else {
	// 如果最大长度没值，则最大的预缓冲区长度为预缓冲区可用长度
		maxPreBufferLength = preBufferLength;
	}
	// 声明一个存放匹配字符串的数组
	uint8_t seq[termLength];
	const void *termBuf = [term bytes];
	// bufLen为当前准备匹配对比是否为终结符一部分的字符串长度。因为终结符不会完整出现在已经读取的数据中，所以最长只会是termLength-1，如果已读的字节不够长，则取已读的字节数
	NSUInteger bufLen = MIN(bytesDone, (termLength - 1));
	// 获取需要比对指针，指向需要比对的第一位
	uint8_t *buf = (uint8_t *)[buffer mutableBytes] + startOffset + bytesDone - bufLen;
	// preLen为匹配可能存在的终结符还需要读取的长度
	NSUInteger preLen = termLength - bufLen;
	// 获取读指针
	const uint8_t *pre = [preBuffer readBuffer];
	// loopCount为对比到末尾需要的次数
	NSUInteger loopCount = bufLen + maxPreBufferLength - termLength + 1; // Plus one. See example above.
	
	NSUInteger result = maxPreBufferLength;
	
	NSUInteger i;
	for (i = 0; i < loopCount; i++)
	{
	// 依次对比
		if (bufLen > 0)
		{
		// 如果当前准备匹配的字节数不为0，则将对应长度的字节拷贝到seq中，再将预缓冲区中一部分字节拷贝到seq中，凑出一个与终结符长度相符合的字符串
			// Combining bytes from buffer and preBuffer
			
			memcpy(seq, buf, bufLen);
			memcpy(seq + bufLen, pre, preLen);
			// 进行比较
			if (memcmp(seq, termBuf, termLength) == 0)
			{
			// 设置要读取的长度为preLen，并标记找到了终结符
				result = preLen;
				found = YES;
				break;
			}
			// 不相等，往后移动
			buf++;
			bufLen--;
			preLen++;
		}
		else
		{
			// Comparing directly from preBuffer
			// 当前准备匹配的字节数为0，则直接从预缓冲区开始对比
			if (memcmp(pre, termBuf, termLength) == 0)
			{
			// 对比吻合，算出在缓冲区中指针移动了多少
				NSUInteger preOffset = pre - [preBuffer readBuffer]; // pointer arithmetic
				// 设置要读取的数量为指针移动的数量加上终结符的长度，并标记找到
				result = preOffset + termLength;
				found = YES;
				break;
			}
			// 不吻合，往后继续对比
			pre++;
		}
	}
	
	// There is no need to avoid resizing the buffer in this particular situation.
	// 返回结果与是否找到终结符
	if (foundPtr) *foundPtr = found;
	return result;
}

/**
 * For read packets with a set terminator, scans the packet buffer for the term.
 * It is assumed the terminator had not been fully read prior to the new bytes.
 * 
 * If the term is found, the number of excess bytes after the term are returned.
 * If the term is not found, this method will return -1.
 * 
 * Note: A return value of zero means the term was found at the very end.
 * 
 * Prerequisites:
 * The given number of bytes have been added to the end of our buffer.
 * Our bytesDone variable has NOT been changed due to the prebuffered bytes.
**/
// 在预缓冲区指定numBytes后寻找终结符，并将超出终结符的长度返回
- (NSInteger)searchForTermAfterPreBuffering:(ssize_t)numBytes
{
	NSAssert(term != nil, @"This method does not apply to non-term reads");
	
	// The implementation of this method is very similar to the above method.
	// See the above method for a discussion of the algorithm used here.
	// 获取buffer指针和起始位置前的长度
	uint8_t *buff = [buffer mutableBytes];
	NSUInteger buffLength = bytesDone + numBytes;
	// 获取终结符指针和终结符长度
	const void *termBuff = [term bytes];
	NSUInteger termLength = [term length];
	
	// Note: We are dealing with unsigned integers,
	// so make sure the math doesn't go below zero.
	// 获取对比起始位置
	NSUInteger i = ((buffLength - numBytes) >= termLength) ? (buffLength - numBytes - termLength + 1) : 0;
	
	while (i + termLength <= buffLength)
	{
		uint8_t *subBuffer = buff + startOffset + i;
		// 对比
		if (memcmp(subBuffer, termBuff, termLength) == 0)
		{
		// 如果找到了终结符，则返回剩余长度
			return buffLength - (i + termLength);
		}
		// 没找到，移动指针继续找
		i++;
	}
	
	return -1;
}


@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * The GCDAsyncWritePacket encompasses the instructions for any given write.
**/
// 写包
@interface GCDAsyncWritePacket : NSObject
{
  @public
	NSData *buffer; // 数据
	NSUInteger bytesDone; // 已读的字节
	long tag;
	NSTimeInterval timeout;
}
// 初始化法方法
- (instancetype)initWithData:(NSData *)d timeout:(NSTimeInterval)t tag:(long)i NS_DESIGNATED_INITIALIZER;
@end

@implementation GCDAsyncWritePacket

// Cover the superclass' designated initializer
- (instancetype)init NS_UNAVAILABLE
{
	NSAssert(0, @"Use the designated initializer");
	return nil;
}
// 初始化属性
- (instancetype)initWithData:(NSData *)d timeout:(NSTimeInterval)t tag:(long)i
{
	if((self = [super init]))
	{
		buffer = d; // Retain not copy. For performance as documented in header file.
		bytesDone = 0;
		timeout = t;
		tag = i;
	}
	return self;
}


@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * The GCDAsyncSpecialPacket encompasses special instructions for interruptions in the read/write queues.
 * This class my be altered to support more than just TLS in the future.
**/
// 特殊包，用于特殊的指令
@interface GCDAsyncSpecialPacket : NSObject
{
  @public
	NSDictionary *tlsSettings;// tls设置
}
// 初始化方法
- (instancetype)initWithTLSSettings:(NSDictionary <NSString*,NSObject*>*)settings NS_DESIGNATED_INITIALIZER;
@end

@implementation GCDAsyncSpecialPacket

// Cover the superclass' designated initializer
- (instancetype)init NS_UNAVAILABLE
{
	NSAssert(0, @"Use the designated initializer");
	return nil;
}
// 初始化属性
- (instancetype)initWithTLSSettings:(NSDictionary <NSString*,NSObject*>*)settings
{
	if((self = [super init]))
	{
		tlsSettings = [settings copy];
	}
	return self;
}


@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@implementation GCDAsyncSocket
{
	uint32_t flags;// 状态标记
	uint16_t config;// 设置
	// 代理对象
	__weak id<GCDAsyncSocketDelegate> delegate;
	// 代理方法执行的队列
	dispatch_queue_t delegateQueue;
	
	int socket4FD;// ipv4的socket
	int socket6FD;// ipv6的socket
	int socketUN;// unix域的socket
	NSURL *socketUrl;// socket的地址
	int stateIndex;// 标识本次连接的索引
	NSData * connectInterface4;
	NSData * connectInterface6;
	NSData * connectInterfaceUN;
	
	dispatch_queue_t socketQueue;// socket的队列
	
	dispatch_source_t accept4Source;
	dispatch_source_t accept6Source;
	dispatch_source_t acceptUNSource;
	dispatch_source_t connectTimer;
	dispatch_source_t readSource;
	dispatch_source_t writeSource;
	dispatch_source_t readTimer;
	dispatch_source_t writeTimer;
	
	NSMutableArray *readQueue;// 读队列
	NSMutableArray *writeQueue;// 写队列
	
	GCDAsyncReadPacket *currentRead;// 当前的读包
	GCDAsyncWritePacket *currentWrite;// 当前的写包
	
	unsigned long socketFDBytesAvailable;
	
	GCDAsyncSocketPreBuffer *preBuffer;// 预缓冲区
		
#if TARGET_OS_IPHONE
	CFStreamClientContext streamContext;
	CFReadStreamRef readStream;// 读流
	CFWriteStreamRef writeStream;// 写流
#endif
	SSLContextRef sslContext;
	GCDAsyncSocketPreBuffer *sslPreBuffer;
	size_t sslWriteCachedLength;
	OSStatus sslErrCode;
    OSStatus lastSSLHandshakeError;
	
	void *IsOnSocketQueueOrTargetQueueKey;
	
	id userData;
    NSTimeInterval alternateAddressDelay;// 连接备用地址的延迟
}
// 初始化，不设置代理对象、socket队列
- (instancetype)init
{
	return [self initWithDelegate:nil delegateQueue:NULL socketQueue:NULL];
}
// 初始化，设置socket队列
- (instancetype)initWithSocketQueue:(dispatch_queue_t)sq
{
	return [self initWithDelegate:nil delegateQueue:NULL socketQueue:sq];
}
// 初始化，设置代理对象和代理队列
- (instancetype)initWithDelegate:(id<GCDAsyncSocketDelegate>)aDelegate delegateQueue:(dispatch_queue_t)dq
{
	return [self initWithDelegate:aDelegate delegateQueue:dq socketQueue:NULL];
}
// 初始化方法，设置代理对象、代理执行的队列和socket队列
- (instancetype)initWithDelegate:(id<GCDAsyncSocketDelegate>)aDelegate delegateQueue:(dispatch_queue_t)dq socketQueue:(dispatch_queue_t)sq
{
	if((self = [super init]))
	{
		delegate = aDelegate;
		delegateQueue = dq;
		
		// sdkiOS6.0之前，arc对gcd对象不支持管理生命周期
		#if !OS_OBJECT_USE_OBJC
		if (dq) dispatch_retain(dq);
		#endif
		
		// 初始化一些ivar
		socket4FD = SOCKET_NULL;
		socket6FD = SOCKET_NULL;
		socketUN = SOCKET_NULL;
		socketUrl = nil;
		stateIndex = 0;
		
		// 判断sq的队列，不可以为并发队列
		if (sq)
		{
			NSAssert(sq != dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0),
			         @"The given socketQueue parameter must not be a concurrent queue.");
			NSAssert(sq != dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
			         @"The given socketQueue parameter must not be a concurrent queue.");
			NSAssert(sq != dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
			         @"The given socketQueue parameter must not be a concurrent queue.");
			
			socketQueue = sq;
			#if !OS_OBJECT_USE_OBJC
			dispatch_retain(sq);
			#endif
		}
		else
		{
		// 如果没传入则创建一个socket所在的队列
			socketQueue = dispatch_queue_create([GCDAsyncSocketQueueName UTF8String], NULL);
		}
		
		// The dispatch_queue_set_specific() and dispatch_get_specific() functions take a "void *key" parameter.
		// From the documentation:
		//
		// > Keys are only compared as pointers and are never dereferenced.
		// > Thus, you can use a pointer to a static variable for a specific subsystem or
		// > any other value that allows you to identify the value uniquely.
		//
		// We're just going to use the memory address of an ivar.
		// Specifically an ivar that is explicitly named for our purpose to make the code more readable.
		//
		// However, it feels tedious (and less readable) to include the "&" all the time:
		// dispatch_get_specific(&IsOnSocketQueueOrTargetQueueKey)
		//
		// So we're going to make it so it doesn't matter if we use the '&' or not,
		// by assigning the value of the ivar to the address of the ivar.
		// Thus: IsOnSocketQueueOrTargetQueueKey == &IsOnSocketQueueOrTargetQueueKey;
		
		// 只需要一个ivar的地址去作为标识的key，为了不用每次都写&，所以这么声明
		IsOnSocketQueueOrTargetQueueKey = &IsOnSocketQueueOrTargetQueueKey;
		
		void *nonNullUnusedPointer = (__bridge void *)self;
		// 指定socket队列一个信息，key是ivar的地址，value是自身，不传入析构函数
		dispatch_queue_set_specific(socketQueue, IsOnSocketQueueOrTargetQueueKey, nonNullUnusedPointer, NULL);
		// 初始化读队列的
		readQueue = [[NSMutableArray alloc] initWithCapacity:5];
		currentRead = nil;
		// 初始化写队列
		writeQueue = [[NSMutableArray alloc] initWithCapacity:5];
		currentWrite = nil;
		
		// 初始化预缓冲区
		preBuffer = [[GCDAsyncSocketPreBuffer alloc] initWithCapacity:(1024 * 4)];
        alternateAddressDelay = 0.3;
	}
	return self;
}
// 销毁方法
- (void)dealloc
{
	LogInfo(@"%@ - %@ (start)", THIS_METHOD, self);
	
	// Set dealloc flag.
	// This is used by closeWithError to ensure we don't accidentally retain ourself.
	// 标记销毁，防止自身此时被意外持有
	flags |= kDealloc;
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
	// 如果当前队列是最初设置的socket队列，则调用关闭连接
		[self closeWithError:nil];
	}
	else
	{
	// 如果不是，则同步到socket队列上，调用关闭连接
		dispatch_sync(socketQueue, ^{
			[self closeWithError:nil];
		});
	}
	// 清空代理对象
	delegate = nil;
	// 清空代理队列，释放
	#if !OS_OBJECT_USE_OBJC
	if (delegateQueue) dispatch_release(delegateQueue);
	#endif
	delegateQueue = NULL;
	// 清空socket队列，释放
	#if !OS_OBJECT_USE_OBJC
	if (socketQueue) dispatch_release(socketQueue);
	#endif
	socketQueue = NULL;
	
	LogInfo(@"%@ - %@ (finish)", THIS_METHOD, self);
}

#pragma mark -
// 根据已创建的socket文件描述符初始化，并指定socket队列
+ (nullable instancetype)socketFromConnectedSocketFD:(int)socketFD socketQueue:(nullable dispatch_queue_t)sq error:(NSError**)error {
  return [self socketFromConnectedSocketFD:socketFD delegate:nil delegateQueue:NULL socketQueue:sq error:error];
}
// 根据已创建的socket文件描述符初始化，并指定代理对象和代理队列
+ (nullable instancetype)socketFromConnectedSocketFD:(int)socketFD delegate:(nullable id<GCDAsyncSocketDelegate>)aDelegate delegateQueue:(nullable dispatch_queue_t)dq error:(NSError**)error {
  return [self socketFromConnectedSocketFD:socketFD delegate:aDelegate delegateQueue:dq socketQueue:NULL error:error];
}
// 根据已创建的socket文件描述符初始化，并指定socket队列、代理对象、代理队列
+ (nullable instancetype)socketFromConnectedSocketFD:(int)socketFD delegate:(nullable id<GCDAsyncSocketDelegate>)aDelegate delegateQueue:(nullable dispatch_queue_t)dq socketQueue:(nullable dispatch_queue_t)sq error:(NSError* __autoreleasing *)error
{
  __block BOOL errorOccured = NO;
  __block NSError *thisError = nil;
  // 先根据指定的队列和代理对象创建一个实例
  GCDAsyncSocket *socket = [[[self class] alloc] initWithDelegate:aDelegate delegateQueue:dq socketQueue:sq];
  // 同步到socket队列，并使用自动释放池来读取socket文件描述符
  dispatch_sync(socket->socketQueue, ^{ @autoreleasepool {
  // 通过socket文件描述符获取socket连接对象的地址
    struct sockaddr addr;
    socklen_t addr_size = sizeof(struct sockaddr);
    int retVal = getpeername(socketFD, (struct sockaddr *)&addr, &addr_size); 
    if (retVal)
    {
    // 如果失败了，则创建一个错误对象，并返回
      NSString *errMsg = NSLocalizedStringWithDefaultValue(@"GCDAsyncSocketOtherError",
                                                           @"GCDAsyncSocket", [NSBundle mainBundle],
                                                           @"Attempt to create socket from socket FD failed. getpeername() failed", nil);
      
      NSDictionary *userInfo = @{NSLocalizedDescriptionKey : errMsg};

      errorOccured = YES;
      thisError = [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketOtherError userInfo:userInfo];
      return;
    }
    // 判断地址属于ipv4还是ipv6，并设置给对应的成员变量
    if (addr.sa_family == AF_INET)
    {
      socket->socket4FD = socketFD;
    }
    else if (addr.sa_family == AF_INET6)
    {
      socket->socket6FD = socketFD;
    }
    else
    {
    // 不属于ipv4和ipv6的地址，则报错并返回错误对象
      NSString *errMsg = NSLocalizedStringWithDefaultValue(@"GCDAsyncSocketOtherError",
                                                           @"GCDAsyncSocket", [NSBundle mainBundle],
                                                           @"Attempt to create socket from socket FD failed. socket FD is neither IPv4 nor IPv6", nil);
      
      NSDictionary *userInfo = @{NSLocalizedDescriptionKey : errMsg};
      
      errorOccured = YES;
      thisError = [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketOtherError userInfo:userInfo];
      return;
    }
    // 标记为开始状态
    socket->flags = kSocketStarted;
    // 处理socket连接成功后的事情，例如打开读写流等
    [socket didConnect:socket->stateIndex];
  }});
  
  if (error && thisError) {
    *error = thisError;
  }
  
  return errorOccured? nil: socket;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Configuration
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// 从socket队列获取代理对象
- (id)delegate
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		return delegate;
	}
	else
	{
		__block id result;
		
		dispatch_sync(socketQueue, ^{
            result = self->delegate;
		});
		
		return result;
	}
}
// 在socket队列设置代理对象，可以选择同步或异步
- (void)setDelegate:(id)newDelegate synchronously:(BOOL)synchronously
{
	dispatch_block_t block = ^{
        self->delegate = newDelegate;
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey)) {
		block();
	}
	else {
		if (synchronously)
			dispatch_sync(socketQueue, block);
		else
			dispatch_async(socketQueue, block);
	}
}
// 在socket队列设置代理对象，默认异步
- (void)setDelegate:(id<GCDAsyncSocketDelegate>)newDelegate
{
	[self setDelegate:newDelegate synchronously:NO];
}
// 在socket队列同步设置代理对象
- (void)synchronouslySetDelegate:(id<GCDAsyncSocketDelegate>)newDelegate
{
	[self setDelegate:newDelegate synchronously:YES];
}
// 在socket队列获取代理队列
- (dispatch_queue_t)delegateQueue
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		return delegateQueue;
	}
	else
	{
		__block dispatch_queue_t result;
		
		dispatch_sync(socketQueue, ^{
            result = self->delegateQueue;
		});
		
		return result;
	}
}
// 在socket队列设置代理队列，可选择同步或异步
- (void)setDelegateQueue:(dispatch_queue_t)newDelegateQueue synchronously:(BOOL)synchronously
{
	dispatch_block_t block = ^{
		
		#if !OS_OBJECT_USE_OBJC
        if (self->delegateQueue) dispatch_release(self->delegateQueue);
		if (newDelegateQueue) dispatch_retain(newDelegateQueue);
		#endif
		
        self->delegateQueue = newDelegateQueue;
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey)) {
		block();
	}
	else {
		if (synchronously)
			dispatch_sync(socketQueue, block);
		else
			dispatch_async(socketQueue, block);
	}
}
// 在socket队列异步设置代理队列
- (void)setDelegateQueue:(dispatch_queue_t)newDelegateQueue
{
	[self setDelegateQueue:newDelegateQueue synchronously:NO];
}
// 在socket队列同步设置代理队列
- (void)synchronouslySetDelegateQueue:(dispatch_queue_t)newDelegateQueue
{
	[self setDelegateQueue:newDelegateQueue synchronously:YES];
}
// 在socket队列同时获取代理对象和代理队列
- (void)getDelegate:(id<GCDAsyncSocketDelegate> *)delegatePtr delegateQueue:(dispatch_queue_t *)delegateQueuePtr
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		if (delegatePtr) *delegatePtr = delegate;
		if (delegateQueuePtr) *delegateQueuePtr = delegateQueue;
	}
	else
	{
		__block id dPtr = NULL;
		__block dispatch_queue_t dqPtr = NULL;
		
		dispatch_sync(socketQueue, ^{
            dPtr = self->delegate;
            dqPtr = self->delegateQueue;
		});
		
		if (delegatePtr) *delegatePtr = dPtr;
		if (delegateQueuePtr) *delegateQueuePtr = dqPtr;
	}
}
// 在socket队列上同时设置代理对象和代理队列，可选择同步或异步
- (void)setDelegate:(id)newDelegate delegateQueue:(dispatch_queue_t)newDelegateQueue synchronously:(BOOL)synchronously
{
	dispatch_block_t block = ^{
		
        self->delegate = newDelegate;
		
		#if !OS_OBJECT_USE_OBJC
        if (self->delegateQueue) dispatch_release(self->delegateQueue);
		if (newDelegateQueue) dispatch_retain(newDelegateQueue);
		#endif
		
        self->delegateQueue = newDelegateQueue;
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey)) {
		block();
	}
	else {
		if (synchronously)
			dispatch_sync(socketQueue, block);
		else
			dispatch_async(socketQueue, block);
	}
}
// 在socket队列同时设置代理对象，异步
- (void)setDelegate:(id<GCDAsyncSocketDelegate>)newDelegate delegateQueue:(dispatch_queue_t)newDelegateQueue
{
	[self setDelegate:newDelegate delegateQueue:newDelegateQueue synchronously:NO];
}
// 在socket队列同步设置代理对象，同步
- (void)synchronouslySetDelegate:(id<GCDAsyncSocketDelegate>)newDelegate delegateQueue:(dispatch_queue_t)newDelegateQueue
{
	[self setDelegate:newDelegate delegateQueue:newDelegateQueue synchronously:YES];
}
// 在socket队列上获取IPv4是否可用
- (BOOL)isIPv4Enabled
{
	// Note: YES means kIPv4Disabled is OFF
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		return ((config & kIPv4Disabled) == 0);
	}
	else
	{
		__block BOOL result;
		
		dispatch_sync(socketQueue, ^{
            result = ((self->config & kIPv4Disabled) == 0);
		});
		
		return result;
	}
}
// 在socket队列上设置IPv4的可用性
- (void)setIPv4Enabled:(BOOL)flag
{
	// Note: YES means kIPv4Disabled is OFF
	
	dispatch_block_t block = ^{
		
		if (flag)
            self->config &= ~kIPv4Disabled;
		else
            self->config |= kIPv4Disabled;
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_async(socketQueue, block);
}
// 在socket队列获取IPv6是否可用
- (BOOL)isIPv6Enabled
{
	// Note: YES means kIPv6Disabled is OFF
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		return ((config & kIPv6Disabled) == 0);
	}
	else
	{
		__block BOOL result;
		
		dispatch_sync(socketQueue, ^{
            result = ((self->config & kIPv6Disabled) == 0);
		});
		
		return result;
	}
}
// 在socket队列上设置IPv6的可用性
- (void)setIPv6Enabled:(BOOL)flag
{
	// Note: YES means kIPv6Disabled is OFF
	
	dispatch_block_t block = ^{
		
		if (flag)
            self->config &= ~kIPv6Disabled;
		else
            self->config |= kIPv6Disabled;
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_async(socketQueue, block);
}
// 在socket队列上获取是否优先IPv4
- (BOOL)isIPv4PreferredOverIPv6
{
	// Note: YES means kPreferIPv6 is OFF
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		return ((config & kPreferIPv6) == 0);
	}
	else
	{
		__block BOOL result;
		
		dispatch_sync(socketQueue, ^{
            result = ((self->config & kPreferIPv6) == 0);
		});
		
		return result;
	}
}
// 在socket队列上设置是否优先IPv4
- (void)setIPv4PreferredOverIPv6:(BOOL)flag
{
	// Note: YES means kPreferIPv6 is OFF
	
	dispatch_block_t block = ^{
		
		if (flag)
            self->config &= ~kPreferIPv6;
		else
            self->config |= kPreferIPv6;
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_async(socketQueue, block);
}
// 在socket队列上获取连接备用域名的延时
- (NSTimeInterval) alternateAddressDelay {
    __block NSTimeInterval delay;
    dispatch_block_t block = ^{
        delay = self->alternateAddressDelay;
    };
    if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
        block();
    else
        dispatch_sync(socketQueue, block);
    return delay;
}
// 在socket队列上设置备用域名的延时
- (void) setAlternateAddressDelay:(NSTimeInterval)delay {
    dispatch_block_t block = ^{
        self->alternateAddressDelay = delay;
    };
    if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
        block();
    else
        dispatch_async(socketQueue, block);
}
// 在socket队列上获取用户数据
- (id)userData
{
	__block id result = nil;
	
	dispatch_block_t block = ^{
		
        result = self->userData;
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	return result;
}
// 在socket队列里设置用户数据
- (void)setUserData:(id)arbitraryUserData
{
	dispatch_block_t block = ^{
		
        if (self->userData != arbitraryUserData)
		{
            self->userData = arbitraryUserData;
		}
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_async(socketQueue, block);
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Accepting
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// 在指定端口创建监听的socket接收客户端连接，不指定服务器用于通信的地址
- (BOOL)acceptOnPort:(uint16_t)port error:(NSError **)errPtr
{
	return [self acceptOnInterface:nil port:port error:errPtr];
}
// 在指定端口创建监听的socket接收客户端连接，指定了服务器用于通信的地址
- (BOOL)acceptOnInterface:(NSString *)inInterface port:(uint16_t)port error:(NSError **)errPtr
{
	LogTrace();
	
	// Just in-case interface parameter is immutable.
	NSString *interface = [inInterface copy];
	
	__block BOOL result = NO;
	__block NSError *err = nil;
	
	// CreateSocket Block
	// This block will be invoked within the dispatch block below.
	// 创建socket的block
	int(^createSocket)(int, NSData*) = ^int (int domain, NSData *interfaceAddr) {
		// 创建socket文件描述符，基于tcp协议
		int socketFD = socket(domain, SOCK_STREAM, 0);
		
		if (socketFD == SOCKET_NULL)
		{
			NSString *reason = @"Error in socket() function";
			err = [self errorWithErrno:errno reason:reason];
			
			return SOCKET_NULL;
		}
		
		int status;
		
		// Set socket options
		// 设置为不阻塞
		status = fcntl(socketFD, F_SETFL, O_NONBLOCK);
		if (status == -1)
		{
			NSString *reason = @"Error enabling non-blocking IO on socket (fcntl)";
			err = [self errorWithErrno:errno reason:reason];
			
			LogVerbose(@"close(socketFD)");
			close(socketFD);
			return SOCKET_NULL;
		}
		// 设置打开地址复用功能，可以允许端口在连接关闭后立即被释放（默认是两分钟会释放）
		int reuseOn = 1;
		status = setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuseOn, sizeof(reuseOn));
		if (status == -1)
		{
			NSString *reason = @"Error enabling address reuse (setsockopt)";
			err = [self errorWithErrno:errno reason:reason];
			
			LogVerbose(@"close(socketFD)");
			close(socketFD);
			return SOCKET_NULL;
		}
		
		// Bind socket
		// 绑定socket到指定的地址
		status = bind(socketFD, (const struct sockaddr *)[interfaceAddr bytes], (socklen_t)[interfaceAddr length]);
		if (status == -1)
		{
			NSString *reason = @"Error in bind() function";
			err = [self errorWithErrno:errno reason:reason];
			
			LogVerbose(@"close(socketFD)");
			close(socketFD);
			return SOCKET_NULL;
		}
		
		// Listen
		// 开始监听
		status = listen(socketFD, 1024);
		if (status == -1)
		{
			NSString *reason = @"Error in listen() function";
			err = [self errorWithErrno:errno reason:reason];
			
			LogVerbose(@"close(socketFD)");
			close(socketFD);
			return SOCKET_NULL;
		}
		
		return socketFD;
	};
	
	// Create dispatch block and run on socketQueue
	
	dispatch_block_t block = ^{ @autoreleasepool {
		// 检查是否有代理对象
        if (self->delegate == nil) // Must have delegate set
		{
			NSString *msg = @"Attempting to accept without a delegate. Set a delegate first.";
			err = [self badConfigError:msg];
			
			return_from_block;
		}
		// 检查是否设置了代理队列
        if (self->delegateQueue == NULL) // Must have delegate queue set
		{
			NSString *msg = @"Attempting to accept without a delegate queue. Set a delegate queue first.";
			err = [self badConfigError:msg];
			
			return_from_block;
		}
		// 获取IPv4和IPv6是否可用
        BOOL isIPv4Disabled = (self->config & kIPv4Disabled) ? YES : NO;
        BOOL isIPv6Disabled = (self->config & kIPv6Disabled) ? YES : NO;
		// 都不可用则报错
		if (isIPv4Disabled && isIPv6Disabled) // Must have IPv4 or IPv6 enabled
		{
			NSString *msg = @"Both IPv4 and IPv6 have been disabled. Must enable at least one protocol first.";
			err = [self badConfigError:msg];
			
			return_from_block;
		}
		// 如果没处于断开连接的状态则报错
		if (![self isDisconnected]) // Must be disconnected
		{
			NSString *msg = @"Attempting to accept while connected or accepting connections. Disconnect first.";
			err = [self badConfigError:msg];
			
			return_from_block;
		}
		
		// Clear queues (spurious read/write requests post disconnect)
		// 清理读写队列
        [self->readQueue removeAllObjects];
        [self->writeQueue removeAllObjects];
		
		// Resolve interface from description
		
		NSMutableData *interface4 = nil;
		NSMutableData *interface6 = nil;
		// 获取IPv4或IPv6的地址
		[self getInterfaceAddress4:&interface4 address6:&interface6 fromDescription:interface port:port];
		// 没获取到则报错
		if ((interface4 == nil) && (interface6 == nil))
		{
			NSString *msg = @"Unknown interface. Specify valid interface by name (e.g. \"en1\") or IP address.";
			err = [self badParamError:msg];
			
			return_from_block;
		}
		// 如果禁用了IPv4但没取到IPv6地址则报错
		if (isIPv4Disabled && (interface6 == nil))
		{
			NSString *msg = @"IPv4 has been disabled and specified interface doesn't support IPv6.";
			err = [self badParamError:msg];
			
			return_from_block;
		}
		// 如果禁用了IPv6但没取到IPv4地址则报错
		if (isIPv6Disabled && (interface4 == nil))
		{
			NSString *msg = @"IPv6 has been disabled and specified interface doesn't support IPv4.";
			err = [self badParamError:msg];
			
			return_from_block;
		}
		// 判断当前IPv4和IPv6是否可用
		BOOL enableIPv4 = !isIPv4Disabled && (interface4 != nil);
		BOOL enableIPv6 = !isIPv6Disabled && (interface6 != nil);
		
		// Create sockets, configure, bind, and listen
		// 创建IPv4的socket
		if (enableIPv4)
		{
			LogVerbose(@"Creating IPv4 socket");
            self->socket4FD = createSocket(AF_INET, interface4);
			
            if (self->socket4FD == SOCKET_NULL)
			{
				return_from_block;
			}
		}
		// 创建IPv6的socket
		if (enableIPv6)
		{
			LogVerbose(@"Creating IPv6 socket");
			if (enableIPv4 && (port == 0))
			{
				// No specific port was specified, so we allowed the OS to pick an available port for us.
				// Now we need to make sure the IPv6 socket listens on the same port as the IPv4 socket.
				// 确保端口和IPv4一致
				struct sockaddr_in6 *addr6 = (struct sockaddr_in6 *)[interface6 mutableBytes];
				addr6->sin6_port = htons([self localPort4]);
			}
			// 创建socket
            self->socket6FD = createSocket(AF_INET6, interface6);
			
            if (self->socket6FD == SOCKET_NULL)
			{
                if (self->socket4FD != SOCKET_NULL)
				{
					LogVerbose(@"close(socket4FD)");
                    close(self->socket4FD);
                    self->socket4FD = SOCKET_NULL;
				}
				
				return_from_block;
			}
		}
		
		// Create accept sources
		// 创建IPv4的源
		if (enableIPv4)
		{
		// 创建读源
            self->accept4Source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, self->socket4FD, 0, self->socketQueue);
            	
            int socketFD = self->socket4FD;
            dispatch_source_t acceptSource = self->accept4Source;
			
			__weak GCDAsyncSocket *weakSelf = self;
			
			// 设置读源的事件
            dispatch_source_set_event_handler(self->accept4Source, ^{ @autoreleasepool {
			#pragma clang diagnostic push
			#pragma clang diagnostic warning "-Wimplicit-retain-self"
				
				__strong GCDAsyncSocket *strongSelf = weakSelf;
				if (strongSelf == nil) return_from_block;
				
				LogVerbose(@"event4Block");
				// 获取连接数，因为此处是listen状态的socketfd触发的，所以拿到的不是字节数，而是全连接队列的长度，也就可以用作连接数
				unsigned long i = 0;
				unsigned long numPendingConnections = dispatch_source_get_data(acceptSource);
				
				LogVerbose(@"numPendingConnections: %lu", numPendingConnections);
				// 先尝试接受连接，如果成功则继续接受，直到失败或到达了先前获取的连接数量为止
				while ([strongSelf doAccept:socketFD] && (++i < numPendingConnections));
				
			#pragma clang diagnostic pop
			}});
			
			// 处理源取消后的操作
            dispatch_source_set_cancel_handler(self->accept4Source, ^{
			#pragma clang diagnostic push
			#pragma clang diagnostic warning "-Wimplicit-retain-self"
				
				#if !OS_OBJECT_USE_OBJC
				LogVerbose(@"dispatch_release(accept4Source)");
				// 释放源，关闭socketFD
				dispatch_release(acceptSource);
				#endif
				
				LogVerbose(@"close(socket4FD)");
				close(socketFD);
			
			#pragma clang diagnostic pop
			});
			
			LogVerbose(@"dispatch_resume(accept4Source)");
			// 启用源
            dispatch_resume(self->accept4Source);
		}
		// 对IPv6处理，逻辑与IPv4一致
		if (enableIPv6)
		{
            self->accept6Source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, self->socket6FD, 0, self->socketQueue);
			
            int socketFD = self->socket6FD;
            dispatch_source_t acceptSource = self->accept6Source;
			
			__weak GCDAsyncSocket *weakSelf = self;
			// 设置源触发事件回调
            dispatch_source_set_event_handler(self->accept6Source, ^{ @autoreleasepool {
			#pragma clang diagnostic push
			#pragma clang diagnostic warning "-Wimplicit-retain-self"
				
				__strong GCDAsyncSocket *strongSelf = weakSelf;
				if (strongSelf == nil) return_from_block;
				
				LogVerbose(@"event6Block");
				// 获取连接数
				unsigned long i = 0;
				unsigned long numPendingConnections = dispatch_source_get_data(acceptSource);
				
				LogVerbose(@"numPendingConnections: %lu", numPendingConnections);
				// 依次接受连接
				while ([strongSelf doAccept:socketFD] && (++i < numPendingConnections));
				
			#pragma clang diagnostic pop
			}});
			// 设置取消后释放和关闭
            dispatch_source_set_cancel_handler(self->accept6Source, ^{
			#pragma clang diagnostic push
			#pragma clang diagnostic warning "-Wimplicit-retain-self"
				
				#if !OS_OBJECT_USE_OBJC
				LogVerbose(@"dispatch_release(accept6Source)");
				dispatch_release(acceptSource);
				#endif
				
				LogVerbose(@"close(socket6FD)");
				close(socketFD);
				
			#pragma clang diagnostic pop
			});
			// 启用源
			LogVerbose(@"dispatch_resume(accept6Source)");
            dispatch_resume(self->accept6Source);
		}
		// 标记socket开始
        self->flags |= kSocketStarted;
		
		result = YES;
	}};
	// 保证在socket队列上调用前面定义的block
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	if (result == NO)
	{
		LogInfo(@"Error in accept: %@", err);
		
		if (errPtr)
			*errPtr = err;
	}
	
	return result;
}
// 在指定url监听unix域的socket连接，并设置在触发的时候依次接收
- (BOOL)acceptOnUrl:(NSURL *)url error:(NSError **)errPtr
{
	LogTrace();
	
	__block BOOL result = NO;
	__block NSError *err = nil;
	
	// CreateSocket Block
	// This block will be invoked within the dispatch block below.
	// 创建socket的block
	int(^createSocket)(int, NSData*) = ^int (int domain, NSData *interfaceAddr) {
		// 创建socket文件描述符
		int socketFD = socket(domain, SOCK_STREAM, 0);
		
		if (socketFD == SOCKET_NULL)
		{
			NSString *reason = @"Error in socket() function";
			err = [self errorWithErrno:errno reason:reason];
			
			return SOCKET_NULL;
		}
		
		int status;
		
		// Set socket options
		// 设置不阻塞
		status = fcntl(socketFD, F_SETFL, O_NONBLOCK);
		if (status == -1)
		{
			NSString *reason = @"Error enabling non-blocking IO on socket (fcntl)";
			err = [self errorWithErrno:errno reason:reason];
			
			LogVerbose(@"close(socketFD)");
			close(socketFD);
			return SOCKET_NULL;
		}
		// 设置打开地址复用功能，可以允许在端口连接关闭后立即被释放（默认是两分钟释放）
		int reuseOn = 1;
		status = setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuseOn, sizeof(reuseOn));
		if (status == -1)
		{
			NSString *reason = @"Error enabling address reuse (setsockopt)";
			err = [self errorWithErrno:errno reason:reason];
			
			LogVerbose(@"close(socketFD)");
			close(socketFD);
			return SOCKET_NULL;
		}
		
		// Bind socket
		// 绑定socket到指定地址
		status = bind(socketFD, (const struct sockaddr *)[interfaceAddr bytes], (socklen_t)[interfaceAddr length]);
		if (status == -1)
		{
			NSString *reason = @"Error in bind() function";
			err = [self errorWithErrno:errno reason:reason];
			
			LogVerbose(@"close(socketFD)");
			close(socketFD);
			return SOCKET_NULL;
		}
		
		// Listen
		// 开始监听
		status = listen(socketFD, 1024);
		if (status == -1)
		{
			NSString *reason = @"Error in listen() function";
			err = [self errorWithErrno:errno reason:reason];
			
			LogVerbose(@"close(socketFD)");
			close(socketFD);
			return SOCKET_NULL;
		}
		
		return socketFD;
	};
	
	// Create dispatch block and run on socketQueue
	
	dispatch_block_t block = ^{ @autoreleasepool {
		// 检查是否有代理对象
        if (self->delegate == nil) // Must have delegate set
		{
			NSString *msg = @"Attempting to accept without a delegate. Set a delegate first.";
			err = [self badConfigError:msg];
			
			return_from_block;
		}
		// 检查是否设置了代理队列
        if (self->delegateQueue == NULL) // Must have delegate queue set
		{
			NSString *msg = @"Attempting to accept without a delegate queue. Set a delegate queue first.";
			err = [self badConfigError:msg];
			
			return_from_block;
		}
		// 如果没处于断开连接的状态则报错
		if (![self isDisconnected]) // Must be disconnected
		{
			NSString *msg = @"Attempting to accept while connected or accepting connections. Disconnect first.";
			err = [self badConfigError:msg];
			
			return_from_block;
		}
		
		// Clear queues (spurious read/write requests post disconnect)
		// 清理读写队列
        [self->readQueue removeAllObjects];
        [self->writeQueue removeAllObjects];
		
		// Remove a previous socket
		// 移除先前的socket
		NSError *error = nil;
		NSFileManager *fileManager = [NSFileManager defaultManager];
		NSString *urlPath = url.path;
		if (urlPath && [fileManager fileExistsAtPath:urlPath]) {
			if (![fileManager removeItemAtURL:url error:&error]) {
				NSString *msg = @"Could not remove previous unix domain socket at given url.";
				err = [self otherError:msg];
				
				return_from_block;
			}
		}
		
		// Resolve interface from description
		// 获取地址
		NSData *interface = [self getInterfaceAddressFromUrl:url];
		
		if (interface == nil)
		{
			NSString *msg = @"Invalid unix domain url. Specify a valid file url that does not exist (e.g. \"file:///tmp/socket\")";
			err = [self badParamError:msg];
			
			return_from_block;
		}
		
		// Create sockets, configure, bind, and listen
		
		LogVerbose(@"Creating unix domain socket");
		// 创建unix域socket
        self->socketUN = createSocket(AF_UNIX, interface);
		
        if (self->socketUN == SOCKET_NULL)
		{
			return_from_block;
		}
		
        self->socketUrl = url;
		
		// Create accept sources
		// 创建读源
        self->acceptUNSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, self->socketUN, 0, self->socketQueue);
		
        int socketFD = self->socketUN;
        dispatch_source_t acceptSource = self->acceptUNSource;
		
		__weak GCDAsyncSocket *weakSelf = self;
		// 设置读源的回调处理
        dispatch_source_set_event_handler(self->acceptUNSource, ^{ @autoreleasepool {
			
			__strong GCDAsyncSocket *strongSelf = weakSelf;
			
			LogVerbose(@"eventUNBlock");
			// 获取连接数
			unsigned long i = 0;
			unsigned long numPendingConnections = dispatch_source_get_data(acceptSource);
			
			LogVerbose(@"numPendingConnections: %lu", numPendingConnections);
			// 依次接受连接
			while ([strongSelf doAccept:socketFD] && (++i < numPendingConnections));
		}});
		
        dispatch_source_set_cancel_handler(self->acceptUNSource, ^{
			// 释放源，关闭socketFD
#if !OS_OBJECT_USE_OBJC
			LogVerbose(@"dispatch_release(acceptUNSource)");
			dispatch_release(acceptSource);
#endif
			
			LogVerbose(@"close(socketUN)");
			close(socketFD);
		});
		
		LogVerbose(@"dispatch_resume(acceptUNSource)");
        dispatch_resume(self->acceptUNSource);
		// 标记为socket开始
        self->flags |= kSocketStarted;
		
		result = YES;
	}};
	// 指定在socket队列中运行
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	if (result == NO)
	{
		LogInfo(@"Error in accept: %@", err);
		
		if (errPtr)
			*errPtr = err;
	}
	
	return result;	
}
// 接受监听的socketFD上的连接
- (BOOL)doAccept:(int)parentSocketFD
{
	LogTrace();
	
	int socketType;
	int childSocketFD;
	NSData *childSocketAddress;
	
	if (parentSocketFD == socket4FD)
	{
	// IPv4的情况
		socketType = 0;
		
		struct sockaddr_in addr;
		socklen_t addrLen = sizeof(addr);
		// 创建一个用于通信的socketfd
		childSocketFD = accept(parentSocketFD, (struct sockaddr *)&addr, &addrLen);
		// 失败则报错
		if (childSocketFD == -1)
		{
			LogWarn(@"Accept failed with error: %@", [self errnoError]);
			return NO;
		}
		// 获取通信对象的地址
		childSocketAddress = [NSData dataWithBytes:&addr length:addrLen];
	}
	else if (parentSocketFD == socket6FD)
	{
	// IPv6的情况
		socketType = 1;
		
		struct sockaddr_in6 addr;
		socklen_t addrLen = sizeof(addr);
		// 创建一个用于通信的socketFD
		childSocketFD = accept(parentSocketFD, (struct sockaddr *)&addr, &addrLen);
		// 失败则报错
		if (childSocketFD == -1)
		{
			LogWarn(@"Accept failed with error: %@", [self errnoError]);
			return NO;
		}
		// 获取通信对象的地址
		childSocketAddress = [NSData dataWithBytes:&addr length:addrLen];
	}
	else // if (parentSocketFD == socketUN)
	{
	// UNIX的socket的情况
		socketType = 2;
		
		struct sockaddr_un addr;
		socklen_t addrLen = sizeof(addr);
		// 创建一个用于通信的socketFD
		childSocketFD = accept(parentSocketFD, (struct sockaddr *)&addr, &addrLen);
		// 失败则容错
		if (childSocketFD == -1)
		{
			LogWarn(@"Accept failed with error: %@", [self errnoError]);
			return NO;
		}
		// 获取通信对象的地址
		childSocketAddress = [NSData dataWithBytes:&addr length:addrLen];
	}
	
	// Enable non-blocking IO on the socket
	// 设置不阻塞
	int result = fcntl(childSocketFD, F_SETFL, O_NONBLOCK);
	if (result == -1)
	{
		LogWarn(@"Error enabling non-blocking IO on accepted socket (fcntl)");
		LogVerbose(@"close(childSocketFD)");
		close(childSocketFD);
		return NO;
	}
	
	// Prevent SIGPIPE signals
	// 设置屏蔽SIGPIPE信号，向已经调用close的socket一端发送数据会产生SIGPIPE信号，导致程序异常退出。这里屏蔽就是希望这种情况程序不会崩溃
	int nosigpipe = 1;
	setsockopt(childSocketFD, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));
	
	// Notify delegate
	
	if (delegateQueue)
	{
		__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;
		
		dispatch_async(delegateQueue, ^{ @autoreleasepool {
			
			// Query delegate for custom socket queue
			
			dispatch_queue_t childSocketQueue = NULL;
			// 通过代理对象获取连接用的socket所在的队列
			if ([theDelegate respondsToSelector:@selector(newSocketQueueForConnectionFromAddress:onSocket:)])
			{
				childSocketQueue = [theDelegate newSocketQueueForConnectionFromAddress:childSocketAddress
				                                                              onSocket:self];
			}
			
			// Create GCDAsyncSocket instance for accepted socket
			// 创建一个连接的socket
			GCDAsyncSocket *acceptedSocket = [[[self class] alloc] initWithDelegate:theDelegate
                                                                      delegateQueue:self->delegateQueue
																		socketQueue:childSocketQueue];
			// 设置对应的socketFD
			if (socketType == 0)
				acceptedSocket->socket4FD = childSocketFD;
			else if (socketType == 1)
				acceptedSocket->socket6FD = childSocketFD;
			else
				acceptedSocket->socketUN = childSocketFD;
			// 设置socket的状态为开始及已连接
			acceptedSocket->flags = (kSocketStarted | kConnected);
			
			// Setup read and write sources for accepted socket
			// 为socket创建读写源
			dispatch_async(acceptedSocket->socketQueue, ^{ @autoreleasepool {
				
				[acceptedSocket setupReadAndWriteSourcesForNewlyConnectedSocket:childSocketFD];
			}});
			
			// Notify delegate
			// 通知代理已经接收了新的连接
			if ([theDelegate respondsToSelector:@selector(socket:didAcceptNewSocket:)])
			{
				[theDelegate socket:self didAcceptNewSocket:acceptedSocket];
			}
			// 释放子队列，此时该队列已经被acceptedSocket持有
			// Release the socket queue returned from the delegate (it was retained by acceptedSocket)
			#if !OS_OBJECT_USE_OBJC
			if (childSocketQueue) dispatch_release(childSocketQueue);
			#endif
			
			// The accepted socket should have been retained by the delegate.
			// Otherwise it gets properly released when exiting the block.
		}});
	}
	
	return YES;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Connecting
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * This method runs through the various checks required prior to a connection attempt.
 * It is shared between the connectToHost and connectToAddress methods.
 * 
**/
// 在连接前执行检查
- (BOOL)preConnectWithInterface:(NSString *)interface error:(NSError **)errPtr
{
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	if (delegate == nil) // Must have delegate set
	{
		if (errPtr)
		{
			NSString *msg = @"Attempting to connect without a delegate. Set a delegate first.";
			*errPtr = [self badConfigError:msg];
		}
		return NO;
	}
	
	if (delegateQueue == NULL) // Must have delegate queue set
	{
		if (errPtr)
		{
			NSString *msg = @"Attempting to connect without a delegate queue. Set a delegate queue first.";
			*errPtr = [self badConfigError:msg];
		}
		return NO;
	}
	
	if (![self isDisconnected]) // Must be disconnected
	{
		if (errPtr)
		{
			NSString *msg = @"Attempting to connect while connected or accepting connections. Disconnect first.";
			*errPtr = [self badConfigError:msg];
		}
		return NO;
	}
	
	BOOL isIPv4Disabled = (config & kIPv4Disabled) ? YES : NO;
	BOOL isIPv6Disabled = (config & kIPv6Disabled) ? YES : NO;
	
	if (isIPv4Disabled && isIPv6Disabled) // Must have IPv4 or IPv6 enabled
	{
		if (errPtr)
		{
			NSString *msg = @"Both IPv4 and IPv6 have been disabled. Must enable at least one protocol first.";
			*errPtr = [self badConfigError:msg];
		}
		return NO;
	}
	
	if (interface)
	{
		NSMutableData *interface4 = nil;
		NSMutableData *interface6 = nil;
		
		[self getInterfaceAddress4:&interface4 address6:&interface6 fromDescription:interface port:0];
		
		if ((interface4 == nil) && (interface6 == nil))
		{
			if (errPtr)
			{
				NSString *msg = @"Unknown interface. Specify valid interface by name (e.g. \"en1\") or IP address.";
				*errPtr = [self badParamError:msg];
			}
			return NO;
		}
		
		if (isIPv4Disabled && (interface6 == nil))
		{
			if (errPtr)
			{
				NSString *msg = @"IPv4 has been disabled and specified interface doesn't support IPv6.";
				*errPtr = [self badParamError:msg];
			}
			return NO;
		}
		
		if (isIPv6Disabled && (interface4 == nil))
		{
			if (errPtr)
			{
				NSString *msg = @"IPv6 has been disabled and specified interface doesn't support IPv4.";
				*errPtr = [self badParamError:msg];
			}
			return NO;
		}
		
		connectInterface4 = interface4;
		connectInterface6 = interface6;
	}
	
	// Clear queues (spurious read/write requests post disconnect)
	[readQueue removeAllObjects];
	[writeQueue removeAllObjects];
	
	return YES;
}
// 在连接前执行检查
- (BOOL)preConnectWithUrl:(NSURL *)url error:(NSError **)errPtr
{
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	if (delegate == nil) // Must have delegate set
	{
		if (errPtr)
		{
			NSString *msg = @"Attempting to connect without a delegate. Set a delegate first.";
			*errPtr = [self badConfigError:msg];
		}
		return NO;
	}
	
	if (delegateQueue == NULL) // Must have delegate queue set
	{
		if (errPtr)
		{
			NSString *msg = @"Attempting to connect without a delegate queue. Set a delegate queue first.";
			*errPtr = [self badConfigError:msg];
		}
		return NO;
	}
	
	if (![self isDisconnected]) // Must be disconnected
	{
		if (errPtr)
		{
			NSString *msg = @"Attempting to connect while connected or accepting connections. Disconnect first.";
			*errPtr = [self badConfigError:msg];
		}
		return NO;
	}
	
	NSData *interface = [self getInterfaceAddressFromUrl:url];
	
	if (interface == nil)
	{
		if (errPtr)
		{
			NSString *msg = @"Unknown interface. Specify valid interface by name (e.g. \"en1\") or IP address.";
			*errPtr = [self badParamError:msg];
		}
		return NO;
	}
	
	connectInterfaceUN = interface;
	
	// Clear queues (spurious read/write requests post disconnect)
	[readQueue removeAllObjects];
	[writeQueue removeAllObjects];
	
	return YES;
}
// 连接指定的地址，不设置超时时间
- (BOOL)connectToHost:(NSString*)host onPort:(uint16_t)port error:(NSError **)errPtr
{
	return [self connectToHost:host onPort:port withTimeout:-1 error:errPtr];
}
// 连接指定的地址并设置超时时间
- (BOOL)connectToHost:(NSString *)host
               onPort:(uint16_t)port
          withTimeout:(NSTimeInterval)timeout
                error:(NSError **)errPtr
{
	return [self connectToHost:host onPort:port viaInterface:nil withTimeout:timeout error:errPtr];
}
// 连接指定的地址并设置超时时间，同时设置自己的ip地址
- (BOOL)connectToHost:(NSString *)inHost
               onPort:(uint16_t)port
         viaInterface:(NSString *)inInterface
          withTimeout:(NSTimeInterval)timeout
                error:(NSError **)errPtr
{
	LogTrace();
	
	// Just in case immutable objects were passed
	NSString *host = [inHost copy];
	NSString *interface = [inInterface copy];
	
	__block BOOL result = NO;
	__block NSError *preConnectErr = nil;
	
	dispatch_block_t block = ^{ @autoreleasepool {
		
		// Check for problems with host parameter
		// 检查host
		if ([host length] == 0)
		{
			NSString *msg = @"Invalid host parameter (nil or \"\"). Should be a domain name or IP address string.";
			preConnectErr = [self badParamError:msg];
			
			return_from_block;
		}
		
		// Run through standard pre-connect checks
		// 检查其他参数
		if (![self preConnectWithInterface:interface error:&preConnectErr])
		{
			return_from_block;
		}
		
		// We've made it past all the checks.
		// It's time to start the connection process.
		// 设置socket开始
        self->flags |= kSocketStarted;
		
		LogVerbose(@"Dispatching DNS lookup...");
		
		// It's possible that the given host parameter is actually a NSMutableString.
		// So we want to copy it now, within this block that will be executed synchronously.
		// This way the asynchronous lookup block below doesn't have to worry about it changing.
		
		NSString *hostCpy = [host copy];
		// 获取当前所属的index
        int aStateIndex = self->stateIndex;
		__weak GCDAsyncSocket *weakSelf = self;
		
		dispatch_queue_t globalConcurrentQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
		dispatch_async(globalConcurrentQueue, ^{ @autoreleasepool {
		#pragma clang diagnostic push
		#pragma clang diagnostic warning "-Wimplicit-retain-self"
			// 根据host和端口号来获取地址组，域名解析
			NSError *lookupErr = nil;
			NSMutableArray *addresses = [[self class] lookupHost:hostCpy port:port error:&lookupErr];
			
			__strong GCDAsyncSocket *strongSelf = weakSelf;
			if (strongSelf == nil) return_from_block;
			
			if (lookupErr)
			{
				// 错误处理
				dispatch_async(strongSelf->socketQueue, ^{ @autoreleasepool {
					
					[strongSelf lookup:aStateIndex didFail:lookupErr];
				}});
			}
			else
			{
				NSData *address4 = nil;
				NSData *address6 = nil;
				// 取出IPv4和IPv6的地址
				for (NSData *address in addresses)
				{
					if (!address4 && [[self class] isIPv4Address:address])
					{
						address4 = address;
					}
					else if (!address6 && [[self class] isIPv6Address:address])
					{
						address6 = address;
					}
				}
				
				dispatch_async(strongSelf->socketQueue, ^{ @autoreleasepool {
					// 调用获取地址成功后的处理，去连接
					[strongSelf lookup:aStateIndex didSucceedWithAddress4:address4 address6:address6];
				}});
			}
			
		#pragma clang diagnostic pop
		}});
		// 开始连接的超时计时器
		[self startConnectTimeout:timeout];
		
		result = YES;
	}};
	// 确保在socket队列上调用
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	
	if (errPtr) *errPtr = preConnectErr;
	return result;
}
// 连接指定地址，不设置自己的地址和超时时间
- (BOOL)connectToAddress:(NSData *)remoteAddr error:(NSError **)errPtr
{
	return [self connectToAddress:remoteAddr viaInterface:nil withTimeout:-1 error:errPtr];
}
// 连接指定地址，不设置自己的地址，但设置超时时间
- (BOOL)connectToAddress:(NSData *)remoteAddr withTimeout:(NSTimeInterval)timeout error:(NSError **)errPtr
{
	return [self connectToAddress:remoteAddr viaInterface:nil withTimeout:timeout error:errPtr];
}
// 连接指定地址，设置自己的地址，设置超时时间
- (BOOL)connectToAddress:(NSData *)inRemoteAddr
            viaInterface:(NSString *)inInterface
             withTimeout:(NSTimeInterval)timeout
                   error:(NSError **)errPtr
{
	LogTrace();
	
	// Just in case immutable objects were passed
	NSData *remoteAddr = [inRemoteAddr copy];
	NSString *interface = [inInterface copy];
	
	__block BOOL result = NO;
	__block NSError *err = nil;
	
	dispatch_block_t block = ^{ @autoreleasepool {
		
		// Check for problems with remoteAddr parameter
		
		NSData *address4 = nil;
		NSData *address6 = nil;
		
		if ([remoteAddr length] >= sizeof(struct sockaddr))
		{
			// 如果地址长度大于等于sockaddr的大小，则创建一个sockaddr指针指向该地址
			const struct sockaddr *sockaddr = (const struct sockaddr *)[remoteAddr bytes];
			
			if (sockaddr->sa_family == AF_INET)
			{
				// 如果是IPv4且长度符合要求，则赋值IPv4
				if ([remoteAddr length] == sizeof(struct sockaddr_in))
				{
					address4 = remoteAddr;
				}
			}
			else if (sockaddr->sa_family == AF_INET6)
			{
				// 如果是IPv6且长度符合要求，则赋值IPv6
				if ([remoteAddr length] == sizeof(struct sockaddr_in6))
				{
					address6 = remoteAddr;
				}
			}
		}
		
		if ((address4 == nil) && (address6 == nil))
		{
			// 如果没取到地址，则报错
			NSString *msg = @"A valid IPv4 or IPv6 address was not given";
			err = [self badParamError:msg];
			
			return_from_block;
		}
		// 检查IPv4和IPv6的可用性，必要时报错
        BOOL isIPv4Disabled = (self->config & kIPv4Disabled) ? YES : NO;
        BOOL isIPv6Disabled = (self->config & kIPv6Disabled) ? YES : NO;
		
		if (isIPv4Disabled && (address4 != nil))
		{
			NSString *msg = @"IPv4 has been disabled and an IPv4 address was passed.";
			err = [self badParamError:msg];
			
			return_from_block;
		}
		
		if (isIPv6Disabled && (address6 != nil))
		{
			NSString *msg = @"IPv6 has been disabled and an IPv6 address was passed.";
			err = [self badParamError:msg];
			
			return_from_block;
		}
		
		// Run through standard pre-connect checks
		// 连接前检查一遍
		if (![self preConnectWithInterface:interface error:&err])
		{
			return_from_block;
		}
		
		// We've made it past all the checks.
		// It's time to start the connection process.
		// 连接对应的地址
		if (![self connectWithAddress4:address4 address6:address6 error:&err])
		{
			return_from_block;
		}
		// 标记socket开始
        self->flags |= kSocketStarted;
		// 开始
		[self startConnectTimeout:timeout];
		
		result = YES;
	}};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	if (result == NO)
	{
		if (errPtr)
			*errPtr = err;
	}
	
	return result;
}
// 连接到指定的地址，且设置超时
- (BOOL)connectToUrl:(NSURL *)url withTimeout:(NSTimeInterval)timeout error:(NSError **)errPtr
{
	LogTrace();
	
	__block BOOL result = NO;
	__block NSError *err = nil;
	
	dispatch_block_t block = ^{ @autoreleasepool {
		
		// Check for problems with host parameter
		// 检查地址
		if ([url.path length] == 0)
		{
			NSString *msg = @"Invalid unix domain socket url.";
			err = [self badParamError:msg];
			
			return_from_block;
		}
		
		// Run through standard pre-connect checks
		// 在连接前进行检查
		if (![self preConnectWithUrl:url error:&err])
		{
			return_from_block;
		}
		
		// We've made it past all the checks.
		// It's time to start the connection process.
		// 标记socket开始
        self->flags |= kSocketStarted;
		
		// Start the normal connection process
		// 开始连接Unix域地址，如果失败则关闭
		NSError *connectError = nil;
        if (![self connectWithAddressUN:self->connectInterfaceUN error:&connectError])
		{
			[self closeWithError:connectError];
			
			return_from_block;
		}
		// 开启连接超时的定时器
		[self startConnectTimeout:timeout];
		
		result = YES;
	}};
	// 在socket队列上执行
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	if (result == NO)
	{
		if (errPtr)
			*errPtr = err;
	}
	
	return result;
}
// 连接到本地服务（Bonjour）
- (BOOL)connectToNetService:(NSNetService *)netService error:(NSError **)errPtr
{
	// 获取地址去连接
	NSArray* addresses = [netService addresses];
	for (NSData* address in addresses)
	{
		BOOL result = [self connectToAddress:address error:errPtr];
		if (result)
		{
			return YES;
		}
	}
	
	return NO;
}
// 域名解析获取地址成功后，进行连接
- (void)lookup:(int)aStateIndex didSucceedWithAddress4:(NSData *)address4 address6:(NSData *)address6
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	NSAssert(address4 || address6, @"Expected at least one valid address");
	// 确保连接的索引没变
	if (aStateIndex != stateIndex)
	{
		LogInfo(@"Ignoring lookupDidSucceed, already disconnected");
		
		// The connect operation has been cancelled.
		// That is, socket was disconnected, or connection has already timed out.
		return;
	}
	
	// Check for problems
	// 检查是否有问题
	BOOL isIPv4Disabled = (config & kIPv4Disabled) ? YES : NO;
	BOOL isIPv6Disabled = (config & kIPv6Disabled) ? YES : NO;
	
	if (isIPv4Disabled && (address6 == nil))
	{
		NSString *msg = @"IPv4 has been disabled and DNS lookup found no IPv6 address.";
		
		[self closeWithError:[self otherError:msg]];
		return;
	}
	
	if (isIPv6Disabled && (address4 == nil))
	{
		NSString *msg = @"IPv6 has been disabled and DNS lookup found no IPv4 address.";
		
		[self closeWithError:[self otherError:msg]];
		return;
	}
	
	// Start the normal connection process
	// 连接地址，如果失败则关闭
	NSError *err = nil;
	if (![self connectWithAddress4:address4 address6:address6 error:&err])
	{
		[self closeWithError:err];
	}
}

/**
 * This method is called if the DNS lookup fails.
 * This method is executed on the socketQueue.
 * 
 * Since the DNS lookup executed synchronously on a global concurrent queue,
 * the original connection request may have already been cancelled or timed-out by the time this method is invoked.
 * The lookupIndex tells us whether the lookup is still valid or not.
**/
// 域名解析获取地址失败后调用的方法
- (void)lookup:(int)aStateIndex didFail:(NSError *)error
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	// 如果当前连接索引变了，则不处理
	if (aStateIndex != stateIndex)
	{
		LogInfo(@"Ignoring lookup:didFail: - already disconnected");
		
		// The connect operation has been cancelled.
		// That is, socket was disconnected, or connection has already timed out.
		return;
	}
	// 结束超时连接的计时器，并关闭
	[self endConnectTimeout];
	[self closeWithError:error];
}
// 在指定接口地址上绑定socketFD
- (BOOL)bindSocket:(int)socketFD toInterface:(NSData *)connectInterface error:(NSError **)errPtr
{
    // Bind the socket to the desired interface (if needed)
    
    if (connectInterface)
    {
        LogVerbose(@"Binding socket...");
        // 如果接口地址存在
        if ([[self class] portFromAddress:connectInterface] > 0)
        {
	    // 
            // Since we're going to be binding to a specific port,
            // we should turn on reuseaddr to allow us to override sockets in time_wait.
            // 如果需要绑定一个指定端口，则需要打开复用的特性，以免绑定失败
            int reuseOn = 1;
            setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuseOn, sizeof(reuseOn));
        }
        // 创建接口地址的指针
        const struct sockaddr *interfaceAddr = (const struct sockaddr *)[connectInterface bytes];
        // 在对应的接口地址绑定socketFD，失败则报错
        int result = bind(socketFD, interfaceAddr, (socklen_t)[connectInterface length]);
        if (result != 0)
        {
            if (errPtr)
                *errPtr = [self errorWithErrno:errno reason:@"Error in bind() function"];
            
            return NO;
        }
    }
    
    return YES;
}
// 创建socketFD
- (int)createSocket:(int)family connectInterface:(NSData *)connectInterface errPtr:(NSError **)errPtr
{
    // 创建对应的socketFD，失败则报错
    int socketFD = socket(family, SOCK_STREAM, 0);
    
    if (socketFD == SOCKET_NULL)
    {
        if (errPtr)
            *errPtr = [self errorWithErrno:errno reason:@"Error in socket() function"];
        
        return socketFD;
    }
    // 在指定的接口地址上绑定socketFD，失败则关闭socketFD
    if (![self bindSocket:socketFD toInterface:connectInterface error:errPtr])
    {
        [self closeSocket:socketFD];
        
        return SOCKET_NULL;
    }
    
    // Prevent SIGPIPE signals
    // 屏蔽SIGPIPE信号
    int nosigpipe = 1;
    setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));
    
    return socketFD;
}
// 连接对应的地址
- (void)connectSocket:(int)socketFD address:(NSData *)address stateIndex:(int)aStateIndex
{
    // If there already is a socket connected, we close socketFD and return
    // 如果已经连接了则关闭此socketFD，并返回
    if (self.isConnected)
    {
        [self closeSocket:socketFD];
        return;
    }
    
    // Start the connection process in a background queue
    
    __weak GCDAsyncSocket *weakSelf = self;
    // 在全局并发队列上执行
    dispatch_queue_t globalConcurrentQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_async(globalConcurrentQueue, ^{
#pragma clang diagnostic push
#pragma clang diagnostic warning "-Wimplicit-retain-self"
        // 连接地址
        int result = connect(socketFD, (const struct sockaddr *)[address bytes], (socklen_t)[address length]);
        int err = errno;
        
        __strong GCDAsyncSocket *strongSelf = weakSelf;
        if (strongSelf == nil) return_from_block;
        // 在socket队列上执行
        dispatch_async(strongSelf->socketQueue, ^{ @autoreleasepool {
            // 如果已经连接了，则关闭socketFD
            if (strongSelf.isConnected)
            {
                [strongSelf closeSocket:socketFD];
                return_from_block;
            }
            
            if (result == 0)
            {
	    	//如果连接成功，则关闭未用到的socket，并调用成功连接的事件
                [self closeUnusedSocket:socketFD];
                
                [strongSelf didConnect:aStateIndex];
            }
            else
            {
	    	//如果连接失败，则关闭该socketFD，并且检测，如果没有其他socket准备尝试连接，则调用连接失败的事件
                [strongSelf closeSocket:socketFD];
                
                // If there are no more sockets trying to connect, we inform the error to the delegate
                if (strongSelf.socket4FD == SOCKET_NULL && strongSelf.socket6FD == SOCKET_NULL)
                {
                    NSError *error = [strongSelf errorWithErrno:err reason:@"Error in connect() function"];
                    [strongSelf didNotConnect:aStateIndex error:error];
                }
            }
        }});
        
#pragma clang diagnostic pop
    });
    
    LogVerbose(@"Connecting...");
}
// 关闭socketFD
- (void)closeSocket:(int)socketFD
{
    if (socketFD != SOCKET_NULL &&
        (socketFD == socket6FD || socketFD == socket4FD))
    {
        close(socketFD);
        
        if (socketFD == socket4FD)
        {
            LogVerbose(@"close(socket4FD)");
            socket4FD = SOCKET_NULL;
        }
        else if (socketFD == socket6FD)
        {
            LogVerbose(@"close(socket6FD)");
            socket6FD = SOCKET_NULL;
        }
    }
}
// 关闭没用到的socketFD
- (void)closeUnusedSocket:(int)usedSocketFD
{
    if (usedSocketFD != socket4FD)
    {
        [self closeSocket:socket4FD];
    }
    else if (usedSocketFD != socket6FD)
    {
        [self closeSocket:socket6FD];
    }
}
// 连接对应的地址
- (BOOL)connectWithAddress4:(NSData *)address4 address6:(NSData *)address6 error:(NSError **)errPtr
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	LogVerbose(@"IPv4: %@:%hu", [[self class] hostFromAddress:address4], [[self class] portFromAddress:address4]);
	LogVerbose(@"IPv6: %@:%hu", [[self class] hostFromAddress:address6], [[self class] portFromAddress:address6]);
	
	// Determine socket type
	
	BOOL preferIPv6 = (config & kPreferIPv6) ? YES : NO;
	
	// Create and bind the sockets
    // 创建对应的socketFD
    if (address4)
    {
        LogVerbose(@"Creating IPv4 socket");
        
        socket4FD = [self createSocket:AF_INET connectInterface:connectInterface4 errPtr:errPtr];
    }
    
    if (address6)
    {
        LogVerbose(@"Creating IPv6 socket");
        
        socket6FD = [self createSocket:AF_INET6 connectInterface:connectInterface6 errPtr:errPtr];
    }
    
    if (socket4FD == SOCKET_NULL && socket6FD == SOCKET_NULL)
    {
        return NO;
    }
	
	int socketFD, alternateSocketFD;
	NSData *address, *alternateAddress;
    // 根据倾向策略来创建主备socketFD和主备地址
    if ((preferIPv6 && socket6FD != SOCKET_NULL) || socket4FD == SOCKET_NULL)
    {
        socketFD = socket6FD;
        alternateSocketFD = socket4FD;
        address = address6;
        alternateAddress = address4;
    }
    else
    {
        socketFD = socket4FD;
        alternateSocketFD = socket6FD;
        address = address4;
        alternateAddress = address6;
    }

    int aStateIndex = stateIndex;
    // 开始连接主地址
    [self connectSocket:socketFD address:address stateIndex:aStateIndex];
    // 如果存在备用地址，则在一定延迟后，连接备用地址
    if (alternateAddress)
    {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(alternateAddressDelay * NSEC_PER_SEC)), socketQueue, ^{
            [self connectSocket:alternateSocketFD address:alternateAddress stateIndex:aStateIndex];
        });
    }
	
	return YES;
}
// 连接对应的unix地址
- (BOOL)connectWithAddressUN:(NSData *)address error:(NSError **)errPtr
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	// Create the socket
	
	int socketFD;
	
	LogVerbose(@"Creating unix domain socket");
	// 创建socketFD
	socketUN = socket(AF_UNIX, SOCK_STREAM, 0);
	
	socketFD = socketUN;
	
	if (socketFD == SOCKET_NULL)
	{
		if (errPtr)
			*errPtr = [self errorWithErrno:errno reason:@"Error in socket() function"];
		
		return NO;
	}
	
	// Bind the socket to the desired interface (if needed)
	
	LogVerbose(@"Binding socket...");
	// 设置复用
	int reuseOn = 1;
	setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuseOn, sizeof(reuseOn));

//	const struct sockaddr *interfaceAddr = (const struct sockaddr *)[address bytes];
//	
//	int result = bind(socketFD, interfaceAddr, (socklen_t)[address length]);
//	if (result != 0)
//	{
//		if (errPtr)
//			*errPtr = [self errnoErrorWithReason:@"Error in bind() function"];
//		
//		return NO;
//	}
	
	// Prevent SIGPIPE signals
	// 屏蔽SIGPIPE信号
	int nosigpipe = 1;
	setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));
	
	// Start the connection process in a background queue
	
	int aStateIndex = stateIndex;
	// 在全局并发队列执行
	dispatch_queue_t globalConcurrentQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
	dispatch_async(globalConcurrentQueue, ^{
		// 连接socket
		const struct sockaddr *addr = (const struct sockaddr *)[address bytes];
		int result = connect(socketFD, addr, addr->sa_len);
		if (result == 0)
		{
		// 连接成功，在socket队列上调用连接成功的方法
            dispatch_async(self->socketQueue, ^{ @autoreleasepool {
				
				[self didConnect:aStateIndex];
			}});
		}
		else
		{
			// TODO: Bad file descriptor
			// 连接失败，在socket队列上调用连接失败的方法
			perror("connect");
			NSError *error = [self errorWithErrno:errno reason:@"Error in connect() function"];
			
            dispatch_async(self->socketQueue, ^{ @autoreleasepool {
				
				[self didNotConnect:aStateIndex error:error];
			}});
		}
	});
	
	LogVerbose(@"Connecting...");
	
	return YES;
}
// 连接成功调用的方法，会创建读写流并处理积压的消息
- (void)didConnect:(int)aStateIndex
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	// 如果stateindex和当前不一致，则直接返回，说明连接已经被取消
	if (aStateIndex != stateIndex)
	{
		LogInfo(@"Ignoring didConnect, already disconnected");
		
		// The connect operation has been cancelled.
		// That is, socket was disconnected, or connection has already timed out.
		return;
	}
	// 设置已连接的标记
	flags |= kConnected;
	// 结束连接计时器
	[self endConnectTimeout];
	
	#if TARGET_OS_IPHONE
	// The endConnectTimeout method executed above incremented the stateIndex.
	// 结束连接计时器会导致stateIndex增加，因此重新赋值
	aStateIndex = stateIndex;
	#endif
	
	// Setup read/write streams (as workaround for specific shortcomings in the iOS platform)
	// 
	// Note:
	// There may be configuration options that must be set by the delegate before opening the streams.
	// The primary example is the kCFStreamNetworkServiceTypeVoIP flag, which only works on an unopened stream.
	// 
	// Thus we wait until after the socket:didConnectToHost:port: delegate method has completed.
	// This gives the delegate time to properly configure the streams if needed.
	// 有些设置必须要在打开流之前，通过delegate设置，为了保证设置，需要等待didConnectToHost的代理方法走完了再执行打开流
	// 打开流的第一步，作为block后续调用
	dispatch_block_t SetupStreamsPart1 = ^{
		#if TARGET_OS_IPHONE
		// 创建读写流
		if (![self createReadAndWriteStream])
		{
			[self closeWithError:[self otherError:@"Error creating CFStreams"]];
			return;
		}
		// 注册流的回调
		if (![self registerForStreamCallbacksIncludingReadWrite:NO])
		{
			[self closeWithError:[self otherError:@"Error in CFStreamSetClient"]];
			return;
		}
		
		#endif
	};
	// 打开流的第二步，作为block后续调用
	dispatch_block_t SetupStreamsPart2 = ^{
		#if TARGET_OS_IPHONE
		// 检测当前要配置的连接是否已经被断开，如果被断开则不处理
        if (aStateIndex != self->stateIndex)
		{
			// The socket has been disconnected.
			return;
		}
		// 添加流到runloop中
		if (![self addStreamsToRunLoop])
		{
			[self closeWithError:[self otherError:@"Error in CFStreamScheduleWithRunLoop"]];
			return;
		}
		// 打开流
		if (![self openStreams])
		{
			[self closeWithError:[self otherError:@"Error creating CFStreams"]];
			return;
		}
		
		#endif
	};
	
	// Notify delegate
	// 获取连接的地址
	NSString *host = [self connectedHost];
	uint16_t port = [self connectedPort];
	NSURL *url = [self connectedUrl];
	
	__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;

// 先配置第一步
	if (delegateQueue && host != nil && [theDelegate respondsToSelector:@selector(socket:didConnectToHost:port:)])
	{
		SetupStreamsPart1();
		
		//先异步到代理队列执行didConnect代理方法，再异步到socket链接执行第二步
		dispatch_async(delegateQueue, ^{ @autoreleasepool {
			
			[theDelegate socket:self didConnectToHost:host port:port];
			
            dispatch_async(self->socketQueue, ^{ @autoreleasepool {
				
				SetupStreamsPart2();
			}});
		}});
	}
	else if (delegateQueue && url != nil && [theDelegate respondsToSelector:@selector(socket:didConnectToUrl:)])
	{
	// 先配置第一步
		SetupStreamsPart1();
		
		// 异步到代理队列，执行didConnectToUrl
		
	dispatch_async(delegateQueue, ^{ @autoreleasepool {
			
			[theDelegate socket:self didConnectToUrl:url];
			// 异步到socket队列，执行第二步
            dispatch_async(self->socketQueue, ^{ @autoreleasepool {
				
				SetupStreamsPart2();
			}});
		}});
	}
	else
	{
	// 两个方法都没实现，则依次直接执行两个步骤
		SetupStreamsPart1();
		SetupStreamsPart2();
	}
		
	// Get the connected socket
	// 获取socket文件描述符
	int socketFD = (socket4FD != SOCKET_NULL) ? socket4FD : (socket6FD != SOCKET_NULL) ? socket6FD : socketUN;
	
	// Enable non-blocking IO on the socket
	// 设置为非阻塞，这样即使文件为空也不会被系统阻塞
	int result = fcntl(socketFD, F_SETFL, O_NONBLOCK);
	if (result == -1)
	{
		NSString *errMsg = @"Error enabling non-blocking IO on socket (fcntl)";
		[self closeWithError:[self otherError:errMsg]];
		
		return;
	}
	
	// Setup our read/write sources
	// 设置读写源
	[self setupReadAndWriteSourcesForNewlyConnectedSocket:socketFD];
	
	// Dequeue any pending read/write requests
	// 处理积压的读写请求
	[self maybeDequeueRead];
	[self maybeDequeueWrite];
}
// 没连接成功调用的方法
- (void)didNotConnect:(int)aStateIndex error:(NSError *)error
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	// 如果连接索引变化了则不处理
	if (aStateIndex != stateIndex)
	{
		LogInfo(@"Ignoring didNotConnect, already disconnected");
		
		// The connect operation has been cancelled.
		// That is, socket was disconnected, or connection has already timed out.
		return;
	}
	// 关闭连接
	[self closeWithError:error];
}
// 开始连接计时器
- (void)startConnectTimeout:(NSTimeInterval)timeout
{
	if (timeout >= 0.0)
	{
		// 如果有超时时间，则创建一个计时器
		connectTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, socketQueue);
		
		__weak GCDAsyncSocket *weakSelf = self;
		
		dispatch_source_set_event_handler(connectTimer, ^{ @autoreleasepool {
		#pragma clang diagnostic push
		#pragma clang diagnostic warning "-Wimplicit-retain-self"
			// 时间到了触发超时方法
			__strong GCDAsyncSocket *strongSelf = weakSelf;
			if (strongSelf == nil) return_from_block;
			
			[strongSelf doConnectTimeout];
			
		#pragma clang diagnostic pop
		}});
		
		#if !OS_OBJECT_USE_OBJC
		dispatch_source_t theConnectTimer = connectTimer;
		dispatch_source_set_cancel_handler(connectTimer, ^{
		#pragma clang diagnostic push
		#pragma clang diagnostic warning "-Wimplicit-retain-self"
			// 取消则释放资源
			LogVerbose(@"dispatch_release(connectTimer)");
			dispatch_release(theConnectTimer);
			
		#pragma clang diagnostic pop
		});
		#endif
		// 开启计时器
		dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
		dispatch_source_set_timer(connectTimer, tt, DISPATCH_TIME_FOREVER, 0);
		
		dispatch_resume(connectTimer);
	}
}
// 取消计算连接超时的计时器
- (void)endConnectTimeout
{
	LogTrace();
	// 取消计时器
	if (connectTimer)
	{
		dispatch_source_cancel(connectTimer);
		connectTimer = NULL;
	}
	
	// Increment stateIndex.
	// This will prevent us from processing results from any related background asynchronous operations.
	// 
	// Note: This should be called from close method even if connectTimer is NULL.
	// This is because one might disconnect a socket prior to a successful connection which had no timeout.
	// 自增stateIndex，防止异步回调的结果被处理
	stateIndex++;
	// 设置连接为空
	if (connectInterface4)
	{
		connectInterface4 = nil;
	}
	if (connectInterface6)
	{
		connectInterface6 = nil;
	}
}
// 连接超时
- (void)doConnectTimeout
{
	LogTrace();
	// 关闭计时器，并关闭连接
	[self endConnectTimeout];
	[self closeWithError:[self connectTimeoutError]];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Disconnecting
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// 关闭连接
- (void)closeWithError:(NSError *)error
{
	LogTrace();
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	// 结束超时的计时
	[self endConnectTimeout];
	// 如果当前读或写正在处理，则终止
	if (currentRead != nil)  [self endCurrentRead];
	if (currentWrite != nil) [self endCurrentWrite];
	// 清空读写队列
	[readQueue removeAllObjects];
	[writeQueue removeAllObjects];
	// 重设缓冲区
	[preBuffer reset];
	
	#if TARGET_OS_IPHONE
	{
		if (readStream || writeStream)
		{
			// 如果读写流创建过，则从runloop中移除
			[self removeStreamsFromRunLoop];
			
			if (readStream)
			{
				// 关闭并释放读流
				CFReadStreamSetClient(readStream, kCFStreamEventNone, NULL, NULL);
				CFReadStreamClose(readStream);
				CFRelease(readStream);
				readStream = NULL;
			}
			if (writeStream)
			{
				// 关闭并释放写流
				CFWriteStreamSetClient(writeStream, kCFStreamEventNone, NULL, NULL);
				CFWriteStreamClose(writeStream);
				CFRelease(writeStream);
				writeStream = NULL;
			}
		}
	}
	#endif
	// 重设ssl缓冲区
	[sslPreBuffer reset];
	sslErrCode = lastSSLHandshakeError = noErr;
	
	if (sslContext)
	{
		// Getting a linker error here about the SSLx() functions?
		// You need to add the Security Framework to your application.
		// 释放ssl上下文
		SSLClose(sslContext);
		
		#if TARGET_OS_IPHONE || (__MAC_OS_X_VERSION_MIN_REQUIRED >= 1080)
		CFRelease(sslContext);
		#else
		SSLDisposeContext(sslContext);
		#endif
		
		sslContext = NULL;
	}
	
	// For some crazy reason (in my opinion), cancelling a dispatch source doesn't
	// invoke the cancel handler if the dispatch source is paused.
	// So we have to unpause the source if needed.
	// This allows the cancel handler to be run, which in turn releases the source and closes the socket.
	// 当源被暂停的时候，取消不会触发取消的handler，因此需要恢复源后在取消
	if (!accept4Source && !accept6Source && !acceptUNSource && !readSource && !writeSource)
	{
		LogVerbose(@"manually closing close");
		// 没有创建过任何源，因此直接关闭socketFD即可
		if (socket4FD != SOCKET_NULL)
		{
			LogVerbose(@"close(socket4FD)");
			close(socket4FD);
			socket4FD = SOCKET_NULL;
		}

		if (socket6FD != SOCKET_NULL)
		{
			LogVerbose(@"close(socket6FD)");
			close(socket6FD);
			socket6FD = SOCKET_NULL;
		}
		
		if (socketUN != SOCKET_NULL)
		{
			LogVerbose(@"close(socketUN)");
			close(socketUN);
			socketUN = SOCKET_NULL;
			unlink(socketUrl.path.fileSystemRepresentation);
			socketUrl = nil;
		}
	}
	else
	{
		// 接受的源从来不会被暂停，所以可以直接取消
		if (accept4Source)
		{
			LogVerbose(@"dispatch_source_cancel(accept4Source)");
			dispatch_source_cancel(accept4Source);
			
			// We never suspend accept4Source
			
			accept4Source = NULL;
		}
		// 接受的源从来不会被暂停，所以可以直接取消
		if (accept6Source)
		{
			LogVerbose(@"dispatch_source_cancel(accept6Source)");
			dispatch_source_cancel(accept6Source);
			
			// We never suspend accept6Source
			
			accept6Source = NULL;
		}
		// 接受的源从来不会被暂停，所以可以直接取消
		if (acceptUNSource)
		{
			LogVerbose(@"dispatch_source_cancel(acceptUNSource)");
			dispatch_source_cancel(acceptUNSource);
			
			// We never suspend acceptUNSource
			
			acceptUNSource = NULL;
		}
		// 读源取消时还需要恢复才能保证触发取消的handler
		if (readSource)
		{
			LogVerbose(@"dispatch_source_cancel(readSource)");
			dispatch_source_cancel(readSource);
			
			[self resumeReadSource];
			
			readSource = NULL;
		}
		// 写源取消时还需要恢复才能保证触发取消的handler
		if (writeSource)
		{
			LogVerbose(@"dispatch_source_cancel(writeSource)");
			dispatch_source_cancel(writeSource);
			
			[self resumeWriteSource];
			
			writeSource = NULL;
		}
		
		// The sockets will be closed by the cancel handlers of the corresponding source
		
		socket4FD = SOCKET_NULL;
		socket6FD = SOCKET_NULL;
		socketUN = SOCKET_NULL;
	}
	
	// If the client has passed the connect/accept method, then the connection has at least begun.
	// Notify delegate that it is now ending.
	// 如果有kSocketStared，说明已经开始连接了，则需要调用代理
	BOOL shouldCallDelegate = (flags & kSocketStarted) ? YES : NO;
	BOOL isDeallocating = (flags & kDealloc) ? YES : NO;
	
	// Clear stored socket info and all flags (config remains as is)
	// 清除储存的sokect的标记和信息
	socketFDBytesAvailable = 0;
	flags = 0;
	sslWriteCachedLength = 0;
	
	if (shouldCallDelegate)
	{
		// 如果需要调用代理，则告知socket已经终止连接
		__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;
		__strong id theSelf = isDeallocating ? nil : self;
		
		if (delegateQueue && [theDelegate respondsToSelector: @selector(socketDidDisconnect:withError:)])
		{
			dispatch_async(delegateQueue, ^{ @autoreleasepool {
				
				[theDelegate socketDidDisconnect:theSelf withError:error];
			}});
		}	
	}
}
// 停止连接
- (void)disconnect
{
	dispatch_block_t block = ^{ @autoreleasepool {
	// 如果socket已经开始，则关闭
        if (self->flags & kSocketStarted)
		{
			[self closeWithError:nil];
		}
	}};
	
	// Synchronous disconnection, as documented in the header file
	// 确保在socket队列上执行
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
}
// 在读完后才停止连接
- (void)disconnectAfterReading
{
	dispatch_async(socketQueue, ^{ @autoreleasepool {
		
        if (self->flags & kSocketStarted)
		{
			// 如果socket已经开始，则设置忽略读写以及在读完后停止连接的标记，然后尝试关闭
            self->flags |= (kForbidReadsWrites | kDisconnectAfterReads);
			[self maybeClose];
		}
	}});
}
// 在写完后才停止连接
- (void)disconnectAfterWriting
{
	dispatch_async(socketQueue, ^{ @autoreleasepool {
		
        if (self->flags & kSocketStarted)
		{
			// 如果socket已经开始，则设置忽略读写以及在写完后停止连接的标记，然后尝试关闭
            self->flags |= (kForbidReadsWrites | kDisconnectAfterWrites);
			[self maybeClose];
		}
	}});
}
// 在读写都做完后才停止连接
- (void)disconnectAfterReadingAndWriting
{
	dispatch_async(socketQueue, ^{ @autoreleasepool {
		
        if (self->flags & kSocketStarted)
		{
			// 如果socket已经开始，则设置忽略读写以及在读写完后停止连接的标记，然后尝试关闭
            self->flags |= (kForbidReadsWrites | kDisconnectAfterReads | kDisconnectAfterWrites);
			[self maybeClose];
		}
	}});
}

/**
 * Closes the socket if possible.
 * That is, if all writes have completed, and we're set to disconnect after writing,
 * or if all reads have completed, and we're set to disconnect after reading.
**/
// 尝试关闭
- (void)maybeClose
{
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	BOOL shouldClose = NO;
	
	if (flags & kDisconnectAfterReads)
	{
		// 如果设置了读后才关闭连接
		if (([readQueue count] == 0) && (currentRead == nil))
		{
			// 如果读队列为空，现在也没有读的任务
			if (flags & kDisconnectAfterWrites)
			{
				// 如果设置了写后才关闭连接
				if (([writeQueue count] == 0) && (currentWrite == nil))
				{
					// 如果写队列为空，现在也没有写的任务，则设置需要关闭
					shouldClose = YES;
				}
			}
			else
			{
				// 如果没设置写后才关闭连接，则直接设置需要关闭
				shouldClose = YES;
			}
		}
	}
	else if (flags & kDisconnectAfterWrites)
	{
		// 如果设置了写后才关闭连接
		if (([writeQueue count] == 0) && (currentWrite == nil))
		{
			// 如果写队列为空，现在也没有写的任务，则设置需要关闭
			shouldClose = YES;
		}
	}
	
	if (shouldClose)
	{
		// 如果需要关闭则关闭
		[self closeWithError:nil];
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Errors
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// 设置错误，并赋予原因
- (NSError *)badConfigError:(NSString *)errMsg
{
	NSDictionary *userInfo = @{NSLocalizedDescriptionKey : errMsg};
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketBadConfigError userInfo:userInfo];
}
// 参数错误，并赋予原因
- (NSError *)badParamError:(NSString *)errMsg
{
	NSDictionary *userInfo = @{NSLocalizedDescriptionKey : errMsg};
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketBadParamError userInfo:userInfo];
}
// 域名解析错误，并赋予原因
+ (NSError *)gaiError:(int)gai_error
{
	NSString *errMsg = [NSString stringWithCString:gai_strerror(gai_error) encoding:NSASCIIStringEncoding];
	NSDictionary *userInfo = @{NSLocalizedDescriptionKey : errMsg};
	
	return [NSError errorWithDomain:@"kCFStreamErrorDomainNetDB" code:gai_error userInfo:userInfo];
}
// socketFD错误，并赋予原因
- (NSError *)errorWithErrno:(int)err reason:(NSString *)reason
{
	NSString *errMsg = [NSString stringWithUTF8String:strerror(err)];
	NSDictionary *userInfo = @{NSLocalizedDescriptionKey : errMsg,
							   NSLocalizedFailureReasonErrorKey : reason};
	
	return [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:userInfo];
}
// socketFD错误
- (NSError *)errnoError
{
	NSString *errMsg = [NSString stringWithUTF8String:strerror(errno)];
	NSDictionary *userInfo = @{NSLocalizedDescriptionKey : errMsg};
	
	return [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:userInfo];
}
// ssl错误
- (NSError *)sslError:(OSStatus)ssl_error
{
	NSString *msg = @"Error code definition can be found in Apple's SecureTransport.h";
	NSDictionary *userInfo = @{NSLocalizedRecoverySuggestionErrorKey : msg};
	
	return [NSError errorWithDomain:@"kCFStreamErrorDomainSSL" code:ssl_error userInfo:userInfo];
}
// 连接超时错误
- (NSError *)connectTimeoutError
{
	NSString *errMsg = NSLocalizedStringWithDefaultValue(@"GCDAsyncSocketConnectTimeoutError",
	                                                     @"GCDAsyncSocket", [NSBundle mainBundle],
	                                                     @"Attempt to connect to host timed out", nil);
	
	NSDictionary *userInfo = @{NSLocalizedDescriptionKey : errMsg};
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketConnectTimeoutError userInfo:userInfo];
}

/**
 * Returns a standard AsyncSocket maxed out error.
**/
// 读溢出错误
- (NSError *)readMaxedOutError
{
	NSString *errMsg = NSLocalizedStringWithDefaultValue(@"GCDAsyncSocketReadMaxedOutError",
														 @"GCDAsyncSocket", [NSBundle mainBundle],
														 @"Read operation reached set maximum length", nil);
	
	NSDictionary *info = @{NSLocalizedDescriptionKey : errMsg};
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketReadMaxedOutError userInfo:info];
}

/**
 * Returns a standard AsyncSocket write timeout error.
**/
// 读超时错误
- (NSError *)readTimeoutError
{
	NSString *errMsg = NSLocalizedStringWithDefaultValue(@"GCDAsyncSocketReadTimeoutError",
	                                                     @"GCDAsyncSocket", [NSBundle mainBundle],
	                                                     @"Read operation timed out", nil);
	
	NSDictionary *userInfo = @{NSLocalizedDescriptionKey : errMsg};
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketReadTimeoutError userInfo:userInfo];
}

/**
 * Returns a standard AsyncSocket write timeout error.
**/
// 写超时错误
- (NSError *)writeTimeoutError
{
	NSString *errMsg = NSLocalizedStringWithDefaultValue(@"GCDAsyncSocketWriteTimeoutError",
	                                                     @"GCDAsyncSocket", [NSBundle mainBundle],
	                                                     @"Write operation timed out", nil);
	
	NSDictionary *userInfo = @{NSLocalizedDescriptionKey : errMsg};
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketWriteTimeoutError userInfo:userInfo];
}
// 连接关闭错误
- (NSError *)connectionClosedError
{
	NSString *errMsg = NSLocalizedStringWithDefaultValue(@"GCDAsyncSocketClosedError",
	                                                     @"GCDAsyncSocket", [NSBundle mainBundle],
	                                                     @"Socket closed by remote peer", nil);
	
	NSDictionary *userInfo = @{NSLocalizedDescriptionKey : errMsg};
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketClosedError userInfo:userInfo];
}
// 其他错误
- (NSError *)otherError:(NSString *)errMsg
{
	NSDictionary *userInfo = @{NSLocalizedDescriptionKey : errMsg};
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketOtherError userInfo:userInfo];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Diagnostics
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// 在socket队列上获取是否断开连接
- (BOOL)isDisconnected
{
	__block BOOL result = NO;
	
	dispatch_block_t block = ^{
        result = (self->flags & kSocketStarted) ? NO : YES;
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	return result;
}
// 在socket队列上获取是否连接
- (BOOL)isConnected
{
	__block BOOL result = NO;
	
	dispatch_block_t block = ^{
        result = (self->flags & kConnected) ? YES : NO;
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	return result;
}
// 在socket队列上获取已连接的地址
- (NSString *)connectedHost
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		if (socket4FD != SOCKET_NULL)
			return [self connectedHostFromSocket4:socket4FD];
		if (socket6FD != SOCKET_NULL)
			return [self connectedHostFromSocket6:socket6FD];
		
		return nil;
	}
	else
	{
		__block NSString *result = nil;
		
		dispatch_sync(socketQueue, ^{ @autoreleasepool {
			
            if (self->socket4FD != SOCKET_NULL)
                result = [self connectedHostFromSocket4:self->socket4FD];
            else if (self->socket6FD != SOCKET_NULL)
                result = [self connectedHostFromSocket6:self->socket6FD];
		}});
		
		return result;
	}
}
// 在socket队列上获取已连接的端口号
- (uint16_t)connectedPort
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		if (socket4FD != SOCKET_NULL)
			return [self connectedPortFromSocket4:socket4FD];
		if (socket6FD != SOCKET_NULL)
			return [self connectedPortFromSocket6:socket6FD];
		
		return 0;
	}
	else
	{
		__block uint16_t result = 0;
		
		dispatch_sync(socketQueue, ^{
			// No need for autorelease pool
			
            if (self->socket4FD != SOCKET_NULL)
                result = [self connectedPortFromSocket4:self->socket4FD];
            else if (self->socket6FD != SOCKET_NULL)
                result = [self connectedPortFromSocket6:self->socket6FD];
		});
		
		return result;
	}
}
// 在socket队列上获取已连接的unix地址
- (NSURL *)connectedUrl
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		if (socketUN != SOCKET_NULL)
			return [self connectedUrlFromSocketUN:socketUN];
		
		return nil;
	}
	else
	{
		__block NSURL *result = nil;
		
		dispatch_sync(socketQueue, ^{ @autoreleasepool {
			
            if (self->socketUN != SOCKET_NULL)
                result = [self connectedUrlFromSocketUN:self->socketUN];
		}});
		
		return result;
	}
}
// 在socket队列上获取本地地址
- (NSString *)localHost
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		if (socket4FD != SOCKET_NULL)
			return [self localHostFromSocket4:socket4FD];
		if (socket6FD != SOCKET_NULL)
			return [self localHostFromSocket6:socket6FD];
		
		return nil;
	}
	else
	{
		__block NSString *result = nil;
		
		dispatch_sync(socketQueue, ^{ @autoreleasepool {
			
            if (self->socket4FD != SOCKET_NULL)
                result = [self localHostFromSocket4:self->socket4FD];
            else if (self->socket6FD != SOCKET_NULL)
                result = [self localHostFromSocket6:self->socket6FD];
		}});
		
		return result;
	}
}
// 在socket队列上获取本地端口
- (uint16_t)localPort
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		if (socket4FD != SOCKET_NULL)
			return [self localPortFromSocket4:socket4FD];
		if (socket6FD != SOCKET_NULL)
			return [self localPortFromSocket6:socket6FD];
		
		return 0;
	}
	else
	{
		__block uint16_t result = 0;
		
		dispatch_sync(socketQueue, ^{
			// No need for autorelease pool
			
            if (self->socket4FD != SOCKET_NULL)
                result = [self localPortFromSocket4:self->socket4FD];
            else if (self->socket6FD != SOCKET_NULL)
                result = [self localPortFromSocket6:self->socket6FD];
		});
		
		return result;
	}
}
// 获取已连接的IPv4地址
- (NSString *)connectedHost4
{
	if (socket4FD != SOCKET_NULL)
		return [self connectedHostFromSocket4:socket4FD];
	
	return nil;
}
// 获取已连接的IPv6地址
- (NSString *)connectedHost6
{
	if (socket6FD != SOCKET_NULL)
		return [self connectedHostFromSocket6:socket6FD];
	
	return nil;
}
// 获取已连接的IPv4端口号
- (uint16_t)connectedPort4
{
	if (socket4FD != SOCKET_NULL)
		return [self connectedPortFromSocket4:socket4FD];
	
	return 0;
}
// 获取已连接的IPv6端口号
- (uint16_t)connectedPort6
{
	if (socket6FD != SOCKET_NULL)
		return [self connectedPortFromSocket6:socket6FD];
	
	return 0;
}
// 获取本地IPv4地址
- (NSString *)localHost4
{
	if (socket4FD != SOCKET_NULL)
		return [self localHostFromSocket4:socket4FD];
	
	return nil;
}
// 获取本地IPv6地址
- (NSString *)localHost6
{
	if (socket6FD != SOCKET_NULL)
		return [self localHostFromSocket6:socket6FD];
	
	return nil;
}
// 获取本地IPv4端口号
- (uint16_t)localPort4
{
	if (socket4FD != SOCKET_NULL)
		return [self localPortFromSocket4:socket4FD];
	
	return 0;
}
// 获取本地IPv6端口号
- (uint16_t)localPort6
{
	if (socket6FD != SOCKET_NULL)
		return [self localPortFromSocket6:socket6FD];
	
	return 0;
}
// 从IPv4套接字获取对端地址
- (NSString *)connectedHostFromSocket4:(int)socketFD
{
	struct sockaddr_in sockaddr4;
	socklen_t sockaddr4len = sizeof(sockaddr4);
	
	if (getpeername(socketFD, (struct sockaddr *)&sockaddr4, &sockaddr4len) < 0)
	{
		return nil;
	}
	return [[self class] hostFromSockaddr4:&sockaddr4];
}
// 从IPv6套接字获取对端地址
- (NSString *)connectedHostFromSocket6:(int)socketFD
{
	struct sockaddr_in6 sockaddr6;
	socklen_t sockaddr6len = sizeof(sockaddr6);
	
	if (getpeername(socketFD, (struct sockaddr *)&sockaddr6, &sockaddr6len) < 0)
	{
		return nil;
	}
	return [[self class] hostFromSockaddr6:&sockaddr6];
}
// 从IPv4套接字获取对端端口
- (uint16_t)connectedPortFromSocket4:(int)socketFD
{
	struct sockaddr_in sockaddr4;
	socklen_t sockaddr4len = sizeof(sockaddr4);
	
	if (getpeername(socketFD, (struct sockaddr *)&sockaddr4, &sockaddr4len) < 0)
	{
		return 0;
	}
	return [[self class] portFromSockaddr4:&sockaddr4];
}
// 从IPv6套接字获取对端端口
- (uint16_t)connectedPortFromSocket6:(int)socketFD
{
	struct sockaddr_in6 sockaddr6;
	socklen_t sockaddr6len = sizeof(sockaddr6);
	
	if (getpeername(socketFD, (struct sockaddr *)&sockaddr6, &sockaddr6len) < 0)
	{
		return 0;
	}
	return [[self class] portFromSockaddr6:&sockaddr6];
}
// 从Unix套接字获取对端地址
- (NSURL *)connectedUrlFromSocketUN:(int)socketFD
{
	struct sockaddr_un sockaddr;
	socklen_t sockaddrlen = sizeof(sockaddr);
	
	if (getpeername(socketFD, (struct sockaddr *)&sockaddr, &sockaddrlen) < 0)
	{
		return 0;
	}
	return [[self class] urlFromSockaddrUN:&sockaddr];
}
// 从socket4FD获取本地地址
- (NSString *)localHostFromSocket4:(int)socketFD
{
	struct sockaddr_in sockaddr4;
	socklen_t sockaddr4len = sizeof(sockaddr4);
	
	if (getsockname(socketFD, (struct sockaddr *)&sockaddr4, &sockaddr4len) < 0)
	{
		return nil;
	}
	return [[self class] hostFromSockaddr4:&sockaddr4];
}
// 从socket6FD获取本地地址
- (NSString *)localHostFromSocket6:(int)socketFD
{
	struct sockaddr_in6 sockaddr6;
	socklen_t sockaddr6len = sizeof(sockaddr6);
	
	if (getsockname(socketFD, (struct sockaddr *)&sockaddr6, &sockaddr6len) < 0)
	{
		return nil;
	}
	return [[self class] hostFromSockaddr6:&sockaddr6];
}
// 从socket4FD获取本地端口号
- (uint16_t)localPortFromSocket4:(int)socketFD
{
	struct sockaddr_in sockaddr4;
	socklen_t sockaddr4len = sizeof(sockaddr4);
	
	if (getsockname(socketFD, (struct sockaddr *)&sockaddr4, &sockaddr4len) < 0)
	{
		return 0;
	}
	return [[self class] portFromSockaddr4:&sockaddr4];
}
// 从socket6FD获取本地端口号
- (uint16_t)localPortFromSocket6:(int)socketFD
{
	struct sockaddr_in6 sockaddr6;
	socklen_t sockaddr6len = sizeof(sockaddr6);
	// 获取socketFD获取套接字
	if (getsockname(socketFD, (struct sockaddr *)&sockaddr6, &sockaddr6len) < 0)
	{
		return 0;
	}
	// 返回端口
	return [[self class] portFromSockaddr6:&sockaddr6];
}
// 在socket队列获取连接的地址
- (NSData *)connectedAddress
{
	__block NSData *result = nil;
	
	dispatch_block_t block = ^{
        if (self->socket4FD != SOCKET_NULL)
		{
			struct sockaddr_in sockaddr4;
			socklen_t sockaddr4len = sizeof(sockaddr4);
			// 如果存在socket4FD，获取socket4FD的对端地址
            if (getpeername(self->socket4FD, (struct sockaddr *)&sockaddr4, &sockaddr4len) == 0)
			{
				result = [[NSData alloc] initWithBytes:&sockaddr4 length:sockaddr4len];
			}
		}
		
        if (self->socket6FD != SOCKET_NULL)
		{
			struct sockaddr_in6 sockaddr6;
			socklen_t sockaddr6len = sizeof(sockaddr6);
			// 如果存在socket6FD，获取socket6FD的对端地址
            if (getpeername(self->socket6FD, (struct sockaddr *)&sockaddr6, &sockaddr6len) == 0)
			{
				result = [[NSData alloc] initWithBytes:&sockaddr6 length:sockaddr6len];
			}
		}
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	return result;
}
// 在socket队列获取本地地址
- (NSData *)localAddress
{
	__block NSData *result = nil;
	
	dispatch_block_t block = ^{
        if (self->socket4FD != SOCKET_NULL)
		{
			struct sockaddr_in sockaddr4;
			socklen_t sockaddr4len = sizeof(sockaddr4);
			// 如果存在socket4FD，获取socket4FD的套接字地址
            if (getsockname(self->socket4FD, (struct sockaddr *)&sockaddr4, &sockaddr4len) == 0)
			{
				result = [[NSData alloc] initWithBytes:&sockaddr4 length:sockaddr4len];
			}
		}
		
        if (self->socket6FD != SOCKET_NULL)
		{
			struct sockaddr_in6 sockaddr6;
			socklen_t sockaddr6len = sizeof(sockaddr6);
			/ 如果存在socket6FD，获取socket6FD的套接字地址
            if (getsockname(self->socket6FD, (struct sockaddr *)&sockaddr6, &sockaddr6len) == 0)
			{
				result = [[NSData alloc] initWithBytes:&sockaddr6 length:sockaddr6len];
			}
		}
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	return result;
}
// 在socket队列判断是否为IPv4的socket
- (BOOL)isIPv4
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		return (socket4FD != SOCKET_NULL);
	}
	else
	{
		__block BOOL result = NO;
		
		dispatch_sync(socketQueue, ^{
            result = (self->socket4FD != SOCKET_NULL);
		});
		
		return result;
	}
}
// 在socket队列判断是否为IPv6的socket
- (BOOL)isIPv6
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		return (socket6FD != SOCKET_NULL);
	}
	else
	{
		__block BOOL result = NO;
		
		dispatch_sync(socketQueue, ^{
            result = (self->socket6FD != SOCKET_NULL);
		});
		
		return result;
	}
}
// 在socket队列判断是否开启了加密
- (BOOL)isSecure
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		return (flags & kSocketSecure) ? YES : NO;
	}
	else
	{
		__block BOOL result;
		
		dispatch_sync(socketQueue, ^{
            result = (self->flags & kSocketSecure) ? YES : NO;
		});
		
		return result;
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Utilities
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Finds the address of an interface description.
 * An inteface description may be an interface name (en0, en1, lo0) or corresponding IP (192.168.4.34).
 * 
 * The interface description may optionally contain a port number at the end, separated by a colon.
 * If a non-zero port parameter is provided, any port number in the interface description is ignored.
 * 
 * The returned value is a 'struct sockaddr' wrapped in an NSMutableData object.
**/
// 从接口描述中取出地址（实质是遍历网卡上取到的接口，取到和接口地址描述一致名字的接口，以此创建对应的地址返回）
- (void)getInterfaceAddress4:(NSMutableData **)interfaceAddr4Ptr
                    address6:(NSMutableData **)interfaceAddr6Ptr
             fromDescription:(NSString *)interfaceDescription
                        port:(uint16_t)port
{
	NSMutableData *addr4 = nil;
	NSMutableData *addr6 = nil;
	
	NSString *interface = nil;

	NSArray *components = [interfaceDescription componentsSeparatedByString:@":"];
	// 取出冒号前面的host地址
	if ([components count] > 0)
	{
		NSString *temp = [components objectAtIndex:0];
		if ([temp length] > 0)
		{
			interface = temp;
		}
	}
	// 取出冒号后面的端口号
	if ([components count] > 1 && port == 0)
	{
		NSString *temp = [components objectAtIndex:1];
		long portL = strtol([temp UTF8String], NULL, 10);
		
		if (portL > 0 && portL <= UINT16_MAX)
		{
			port = (uint16_t)portL;
		}
	}
	
	if (interface == nil)
	{
		// ANY address
		// 如果没取到接口地址，那么就创建一个0.0.0.0的地址（表明不确定地址或任意地址）
		struct sockaddr_in sockaddr4;
		memset(&sockaddr4, 0, sizeof(sockaddr4));
		
		sockaddr4.sin_len         = sizeof(sockaddr4);
		sockaddr4.sin_family      = AF_INET;
		sockaddr4.sin_port        = htons(port);
		sockaddr4.sin_addr.s_addr = htonl(INADDR_ANY);
		
		struct sockaddr_in6 sockaddr6;
		memset(&sockaddr6, 0, sizeof(sockaddr6));
		
		sockaddr6.sin6_len       = sizeof(sockaddr6);
		sockaddr6.sin6_family    = AF_INET6;
		sockaddr6.sin6_port      = htons(port);
		sockaddr6.sin6_addr      = in6addr_any;
		
		addr4 = [NSMutableData dataWithBytes:&sockaddr4 length:sizeof(sockaddr4)];
		addr6 = [NSMutableData dataWithBytes:&sockaddr6 length:sizeof(sockaddr6)];
	}
	else if ([interface isEqualToString:@"localhost"] || [interface isEqualToString:@"loopback"])
	{
		// LOOPBACK address
		// 如果为本机或环回地址（允许计算机的软件在本机上进行网络通信），则创建对应的地址（一般是127.0.0.1-127.255.255.254）
		struct sockaddr_in sockaddr4;
		memset(&sockaddr4, 0, sizeof(sockaddr4));
		
		sockaddr4.sin_len         = sizeof(sockaddr4);
		sockaddr4.sin_family      = AF_INET;
		sockaddr4.sin_port        = htons(port);
		sockaddr4.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		
		struct sockaddr_in6 sockaddr6;
		memset(&sockaddr6, 0, sizeof(sockaddr6));
		
		sockaddr6.sin6_len       = sizeof(sockaddr6);
		sockaddr6.sin6_family    = AF_INET6;
		sockaddr6.sin6_port      = htons(port);
		sockaddr6.sin6_addr      = in6addr_loopback;
		
		addr4 = [NSMutableData dataWithBytes:&sockaddr4 length:sizeof(sockaddr4)];
		addr6 = [NSMutableData dataWithBytes:&sockaddr6 length:sizeof(sockaddr6)];
	}
	else
	{
		// 取到了接口地址
		const char *iface = [interface UTF8String];
		
		struct ifaddrs *addrs;
		const struct ifaddrs *cursor;
		// 尝试获取本机网卡上的ip地址
		if ((getifaddrs(&addrs) == 0))
		{
			// 取到了ip地址，则赋值给cursor
			cursor = addrs;
			while (cursor != NULL)
			{
				// 只要cursor还有值
				if ((addr4 == nil) && (cursor->ifa_addr->sa_family == AF_INET))
				{
					// IPv4
					// 如果没取到IPv4的值，且当前cursor持有的接口地址属于IPv4，则将其赋值给nativeAddr4
					struct sockaddr_in nativeAddr4;
					memcpy(&nativeAddr4, cursor->ifa_addr, sizeof(nativeAddr4));
					
					if (strcmp(cursor->ifa_name, iface) == 0)
					{
						// Name match
						// 如果该接口的名字与设置的接口名字一直，则把设置的端口号赋值给该地址
						nativeAddr4.sin_port = htons(port);
						// 创建IPv4的地址数据
						addr4 = [NSMutableData dataWithBytes:&nativeAddr4 length:sizeof(nativeAddr4)];
					}
					else
					{
						// 如果名字不一致
						char ip[INET_ADDRSTRLEN];
						// 把接口的地址转为本机字节
						const char *conversion = inet_ntop(AF_INET, &nativeAddr4.sin_addr, ip, sizeof(ip));
						
						if ((conversion != NULL) && (strcmp(ip, iface) == 0))
						{
							// IP match
							// 如果转换后的地址与设置的地址一直，则设置端口号并创建IPv4的地址数据
							nativeAddr4.sin_port = htons(port);
							
							addr4 = [NSMutableData dataWithBytes:&nativeAddr4 length:sizeof(nativeAddr4)];
						}
					}
				}
				else if ((addr6 == nil) && (cursor->ifa_addr->sa_family == AF_INET6))
				{
					// IPv6
					// 如果没取到IPv6的值，且当前cursor持有的接口地址属于IPv46，则将其赋值给nativeAddr6
					struct sockaddr_in6 nativeAddr6;
					memcpy(&nativeAddr6, cursor->ifa_addr, sizeof(nativeAddr6));
					
					if (strcmp(cursor->ifa_name, iface) == 0)
					{
						// Name match
						// 如果该接口的名字与设置的接口名字一直，则把设置的端口号赋值给该地址
						nativeAddr6.sin6_port = htons(port);
						// 创建IPv6的地址数据
						addr6 = [NSMutableData dataWithBytes:&nativeAddr6 length:sizeof(nativeAddr6)];
					}
					else
					{
						// 如果名字不一致
						char ip[INET6_ADDRSTRLEN];
						// 把接口的地址转为本机字节
						const char *conversion = inet_ntop(AF_INET6, &nativeAddr6.sin6_addr, ip, sizeof(ip));
						
						if ((conversion != NULL) && (strcmp(ip, iface) == 0))
						{
							// IP match
							// 如果转换后的地址与设置的地址一直，则设置端口号并创建IPv6的地址数据
							nativeAddr6.sin6_port = htons(port);
							
							addr6 = [NSMutableData dataWithBytes:&nativeAddr6 length:sizeof(nativeAddr6)];
						}
					}
				}
				// 指向下一个地址
				cursor = cursor->ifa_next;
			}
			// 释放
			freeifaddrs(addrs);
		}
	}
	// 将取到的地址赋值
	if (interfaceAddr4Ptr) *interfaceAddr4Ptr = addr4;
	if (interfaceAddr6Ptr) *interfaceAddr6Ptr = addr6;
}
// 从url中获取接口地址
- (NSData *)getInterfaceAddressFromUrl:(NSURL *)url
{
	// 检查url参数
	NSString *path = url.path;
	if (path.length == 0) {
		return nil;
	}
	// 创建unix套接字地址
    struct sockaddr_un nativeAddr;
    nativeAddr.sun_family = AF_UNIX;
    strlcpy(nativeAddr.sun_path, path.fileSystemRepresentation, sizeof(nativeAddr.sun_path));
    nativeAddr.sun_len = (unsigned char)SUN_LEN(&nativeAddr);
    NSData *interface = [NSData dataWithBytes:&nativeAddr length:sizeof(struct sockaddr_un)];
	
	return interface;
}

- (void)setupReadAndWriteSourcesForNewlyConnectedSocket:(int)socketFD
{
// 创建gcd读写源
	readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, socketFD, 0, socketQueue);
	writeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, socketFD, 0, socketQueue);
	
	// Setup event handlers
	
	__weak GCDAsyncSocket *weakSelf = self;
	
	// 设置读源的处理句柄
	dispatch_source_set_event_handler(readSource, ^{ @autoreleasepool {
	#pragma clang diagnostic push
	#pragma clang diagnostic warning "-Wimplicit-retain-self"
		
		__strong GCDAsyncSocket *strongSelf = weakSelf;
		if (strongSelf == nil) return_from_block;
		
		LogVerbose(@"readEventBlock");
		// 获取可读取的字节大小
		strongSelf->socketFDBytesAvailable = dispatch_source_get_data(strongSelf->readSource);
		LogVerbose(@"socketFDBytesAvailable: %lu", strongSelf->socketFDBytesAvailable);
		// 处理读取
		if (strongSelf->socketFDBytesAvailable > 0)
			[strongSelf doReadData];
		else
			[strongSelf doReadEOF];
		
	#pragma clang diagnostic pop
	}});
	
	// 设置写源的处理句柄
	dispatch_source_set_event_handler(writeSource, ^{ @autoreleasepool {
	#pragma clang diagnostic push
	#pragma clang diagnostic warning "-Wimplicit-retain-self"
		
		__strong GCDAsyncSocket *strongSelf = weakSelf;
		if (strongSelf == nil) return_from_block;
		
		LogVerbose(@"writeEventBlock");
		// 设置可以接收字节的标记，然后写入
		strongSelf->flags |= kSocketCanAcceptBytes;
		[strongSelf doWriteData];
		
	#pragma clang diagnostic pop
	}});
	
	// Setup cancel handlers
	
	__block int socketFDRefCount = 2;
	
	#if !OS_OBJECT_USE_OBJC
	dispatch_source_t theReadSource = readSource;
	dispatch_source_t theWriteSource = writeSource;
	#endif
	
	// 设置取消读源的处理，会释放读源，并在有必要的时候断开socket
	dispatch_source_set_cancel_handler(readSource, ^{
	#pragma clang diagnostic push
	#pragma clang diagnostic warning "-Wimplicit-retain-self"
		
		LogVerbose(@"readCancelBlock");
		
		#if !OS_OBJECT_USE_OBJC
		LogVerbose(@"dispatch_release(readSource)");
		dispatch_release(theReadSource);
		#endif
		
		if (--socketFDRefCount == 0)
		{
			LogVerbose(@"close(socketFD)");
			close(socketFD);
		}
		
	#pragma clang diagnostic pop
	});
	
	// 设置取消写源的处理，会释放写源，并在有必要的时候断开socket
	dispatch_source_set_cancel_handler(writeSource, ^{
	#pragma clang diagnostic push
	#pragma clang diagnostic warning "-Wimplicit-retain-self"
		
		LogVerbose(@"writeCancelBlock");
		
		#if !OS_OBJECT_USE_OBJC
		LogVerbose(@"dispatch_release(writeSource)");
		dispatch_release(theWriteSource);
		#endif
		
		if (--socketFDRefCount == 0)
		{
			LogVerbose(@"close(socketFD)");
			close(socketFD);
		}
		
	#pragma clang diagnostic pop
	});
	
	// We will not be able to read until data arrives.
	// But we should be able to write immediately.
	// 设置可读字节为0，并且清除读源暂停的标记，恢复读源
	socketFDBytesAvailable = 0;
	flags &= ~kReadSourceSuspended;
	
	LogVerbose(@"dispatch_resume(readSource)");
	dispatch_resume(readSource);
	// 添加socket可以接收字节的标记，以及写源暂停的标记
	flags |= kSocketCanAcceptBytes;
	flags |= kWriteSourceSuspended;
}
// 获取是否为流的方式加密
- (BOOL)usingCFStreamForTLS
{
	#if TARGET_OS_IPHONE
	
	if ((flags & kSocketSecure) && (flags & kUsingCFStreamForTLS))
	{
		// The startTLS method was given the GCDAsyncSocketUseCFStreamForTLS flag.
		
		return YES;
	}
	
	#endif
	
	return NO;
}
// 获取是否使用了TLS传输
- (BOOL)usingSecureTransportForTLS
{
	// Invoking this method is equivalent to ![self usingCFStreamForTLS] (just more readable)
	
	#if TARGET_OS_IPHONE
	
	if ((flags & kSocketSecure) && (flags & kUsingCFStreamForTLS))
	{
		// The startTLS method was given the GCDAsyncSocketUseCFStreamForTLS flag.
		
		return NO;
	}
	
	#endif
	
	return YES;
}
// 暂停读源
- (void)suspendReadSource
{
	if (!(flags & kReadSourceSuspended))
	{
		// 如果读源没被暂停，则恢复，并且设置标记
		LogVerbose(@"dispatch_suspend(readSource)");
		
		dispatch_suspend(readSource);
		flags |= kReadSourceSuspended;
	}
}
// 恢复读源
- (void)resumeReadSource
{
	if (flags & kReadSourceSuspended)
	{
		// 如果读源被暂停了，则恢复，并且设置标记
		LogVerbose(@"dispatch_resume(readSource)");
		
		dispatch_resume(readSource);
		flags &= ~kReadSourceSuspended;
	}
}
// 暂停写源
- (void)suspendWriteSource
{
	if (!(flags & kWriteSourceSuspended))
	{
		// 如果写源没被暂停，则恢复，并且设置标记
		LogVerbose(@"dispatch_suspend(writeSource)");
		
		dispatch_suspend(writeSource);
		flags |= kWriteSourceSuspended;
	}
}
// 恢复写源
- (void)resumeWriteSource
{
	if (flags & kWriteSourceSuspended)
	{
		// 如果写源被暂停了，则恢复，并且设置标记
		LogVerbose(@"dispatch_resume(writeSource)");
		
		dispatch_resume(writeSource);
		flags &= ~kWriteSourceSuspended;
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Reading
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// 读取数据并设置超时时间和tag，不设置缓冲数据和最大长度
- (void)readDataWithTimeout:(NSTimeInterval)timeout tag:(long)tag
{
	[self readDataWithTimeout:timeout buffer:nil bufferOffset:0 maxLength:0 tag:tag];
}
// 读取数据并设置超时时间、缓冲数据、缓冲数据偏移量、tag，不设置最大长度
- (void)readDataWithTimeout:(NSTimeInterval)timeout
                     buffer:(NSMutableData *)buffer
               bufferOffset:(NSUInteger)offset
                        tag:(long)tag
{
	[self readDataWithTimeout:timeout buffer:buffer bufferOffset:offset maxLength:0 tag:tag];
}
// 读取数据并设置超时时间、缓冲数据、缓冲数据偏移量、最大长度、tag
- (void)readDataWithTimeout:(NSTimeInterval)timeout
                     buffer:(NSMutableData *)buffer
               bufferOffset:(NSUInteger)offset
                  maxLength:(NSUInteger)length
                        tag:(long)tag
{
// 如果偏移量大于缓冲本身的长度那就报错
	if (offset > [buffer length]) {
		LogWarn(@"Cannot read: offset > [buffer length]");
		return;
	}
	// 根据超时、缓冲数据和偏移量创建一个读包，不设置读取长度和终结符
	GCDAsyncReadPacket *packet = [[GCDAsyncReadPacket alloc] initWithData:buffer
	                                                          startOffset:offset
	                                                            maxLength:length
	                                                              timeout:timeout
	                                                           readLength:0
	                                                           terminator:nil
	                                                                  tag:tag];
	
	dispatch_async(socketQueue, ^{ @autoreleasepool {
		
		LogTrace();
		
        if ((self->flags & kSocketStarted) && !(self->flags & kForbidReadsWrites))
		{
		// 如果socket已经开始，且没有屏蔽读写，则将包添加到读队列，尝试读
            [self->readQueue addObject:packet];
			[self maybeDequeueRead];
		}
	}});
	
	// Do not rely on the block being run in order to release the packet,
	// as the queue might get released without the block completing.
}
// 读取到指定长度的数据，并设置超时和tag
- (void)readDataToLength:(NSUInteger)length withTimeout:(NSTimeInterval)timeout tag:(long)tag
{
	[self readDataToLength:length withTimeout:timeout buffer:nil bufferOffset:0 tag:tag];
}
// 读取到指定长度的数据，并设置超时、tag、缓冲数据、缓冲偏移量
- (void)readDataToLength:(NSUInteger)length
             withTimeout:(NSTimeInterval)timeout
                  buffer:(NSMutableData *)buffer
            bufferOffset:(NSUInteger)offset
                     tag:(long)tag
{
// 检查参数
	if (length == 0) {
		LogWarn(@"Cannot read: length == 0");
		return;
	}
	if (offset > [buffer length]) {
		LogWarn(@"Cannot read: offset > [buffer length]");
		return;
	}
	// 根据缓冲数据、缓冲偏移量、超时、读取长度、tag创建读包，不设置最大长度和终结符
	GCDAsyncReadPacket *packet = [[GCDAsyncReadPacket alloc] initWithData:buffer
	                                                          startOffset:offset
	                                                            maxLength:0
	                                                              timeout:timeout
	                                                           readLength:length
	                                                           terminator:nil
	                                                                  tag:tag];
	
	dispatch_async(socketQueue, ^{ @autoreleasepool {
		
		LogTrace();
		
        if ((self->flags & kSocketStarted) && !(self->flags & kForbidReadsWrites))
		{
		// 如果socket已经开始，且没有屏蔽读写，则将包添加到读队列，尝试读
            [self->readQueue addObject:packet];
			[self maybeDequeueRead];
		}
	}});
	
	// Do not rely on the block being run in order to release the packet,
	// as the queue might get released without the block completing.
}
// 读取数据到指定的数据后停止，设置超时和tag
- (void)readDataToData:(NSData *)data withTimeout:(NSTimeInterval)timeout tag:(long)tag
{
	[self readDataToData:data withTimeout:timeout buffer:nil bufferOffset:0 maxLength:0 tag:tag];
}
// 读取数据到指定的数据后停止，设置超时、缓冲数据、偏移量、tag
- (void)readDataToData:(NSData *)data
           withTimeout:(NSTimeInterval)timeout
                buffer:(NSMutableData *)buffer
          bufferOffset:(NSUInteger)offset
                   tag:(long)tag
{
	[self readDataToData:data withTimeout:timeout buffer:buffer bufferOffset:offset maxLength:0 tag:tag];
}
// 读取数据到指定的数据后停止，设置超时、最大长度、tag
- (void)readDataToData:(NSData *)data withTimeout:(NSTimeInterval)timeout maxLength:(NSUInteger)length tag:(long)tag
{
	[self readDataToData:data withTimeout:timeout buffer:nil bufferOffset:0 maxLength:length tag:tag];
}
// 读取数据到指定的数据后停止，设置超时、缓冲数据、最大长度、偏移量、tag
- (void)readDataToData:(NSData *)data
           withTimeout:(NSTimeInterval)timeout
                buffer:(NSMutableData *)buffer
          bufferOffset:(NSUInteger)offset
             maxLength:(NSUInteger)maxLength
                   tag:(long)tag
{
// 检查参数
	if ([data length] == 0) {
		LogWarn(@"Cannot read: [data length] == 0");
		return;
	}
	if (offset > [buffer length]) {
		LogWarn(@"Cannot read: offset > [buffer length]");
		return;
	}
	if (maxLength > 0 && maxLength < [data length]) {
		LogWarn(@"Cannot read: maxLength > 0 && maxLength < [data length]");
		return;
	}
	// 根据缓冲数据、缓冲偏移量、超时、最大长度、tag、终结符数据创建读包，不设置读取长度
	GCDAsyncReadPacket *packet = [[GCDAsyncReadPacket alloc] initWithData:buffer
	                                                          startOffset:offset
	                                                            maxLength:maxLength
	                                                              timeout:timeout
	                                                           readLength:0
	                                                           terminator:data
	                                                                  tag:tag];
	
	dispatch_async(socketQueue, ^{ @autoreleasepool {
		
		LogTrace();
		
        if ((self->flags & kSocketStarted) && !(self->flags & kForbidReadsWrites))
		{
		// 如果socket已经开始，且没有屏蔽读写，则将包添加到读队列，尝试读
            [self->readQueue addObject:packet];
			[self maybeDequeueRead];
		}
	}});
	
	// Do not rely on the block being run in order to release the packet,
	// as the queue might get released without the block completing.
}
// 获取当前的读取进度，同时获取tag、已完成的字节和总字节数
- (float)progressOfReadReturningTag:(long *)tagPtr bytesDone:(NSUInteger *)donePtr total:(NSUInteger *)totalPtr
{
	__block float result = 0.0F;
	
	dispatch_block_t block = ^{
		
        if (!self->currentRead || ![self->currentRead isKindOfClass:[GCDAsyncReadPacket class]])
		{
		// 如果并不在读，则清空指针
			// We're not reading anything right now.
			
			if (tagPtr != NULL)   *tagPtr = 0;
			if (donePtr != NULL)  *donePtr = 0;
			if (totalPtr != NULL) *totalPtr = 0;
			
			result = NAN;
		}
		else
		{
			// It's only possible to know the progress of our read if we're reading to a certain length.
			// If we're reading to data, we of course have no idea when the data will arrive.
			// If we're reading to timeout, then we have no idea when the next chunk of data will arrive.
			
            NSUInteger done = self->currentRead->bytesDone;
            NSUInteger total = self->currentRead->readLength;
			// 将tag、完成字节数、总字节数传入外部指针
            if (tagPtr != NULL)   *tagPtr = self->currentRead->tag;
			if (donePtr != NULL)  *donePtr = done;
			if (totalPtr != NULL) *totalPtr = total;
			// 计算百分比并返回
			if (total > 0)
				result = (float)done / (float)total;
			else
				result = 1.0F;
		}
	};
	// 在socket队列执行
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	return result;
}

/**
 * This method starts a new read, if needed.
 * 
 * It is called when:
 * - a user requests a read
 * - after a read request has finished (to handle the next request)
 * - immediately after the socket opens to handle any pending requests
 * 
 * This method also handles auto-disconnect post read/write completion.
**/
/* 尝试读取，被调用的时机：
1 用户请求了读取
2 在一个读请求结束后
3 在socket打开后去处理积压的请求
*/
- (void)maybeDequeueRead
{
	LogTrace();
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	// If we're not currently processing a read AND we have an available read stream
	if ((currentRead == nil) && (flags & kConnected))
	{
	// 如果当前没在读，且socket已经连接上
		if ([readQueue count] > 0)
		{
		// 如果当前没在读，且socket已经连接上
			// Dequeue the next object in the write queue
			// 从读队列里取出第一个并从队列中移除
			currentRead = [readQueue objectAtIndex:0];
			[readQueue removeObjectAtIndex:0];
			
			if ([currentRead isKindOfClass:[GCDAsyncSpecialPacket class]])
			{
			// 如果是特殊包，则尝试启用TLS
				LogVerbose(@"Dequeued GCDAsyncSpecialPacket");
				
				// Attempt to start TLS
				// 设置启用读TLS
				flags |= kStartingReadTLS;
				
				// This method won't do anything unless both kStartingReadTLS and kStartingWriteTLS are set
				// 尝试启用TLS
				[self maybeStartTLS];
			}
			else
			{
				// 如果不是特殊包，就普通读取
				LogVerbose(@"Dequeued GCDAsyncReadPacket");
				
				// Setup read timer (if needed)
				// 设置读取的计时器，并开始读取
				[self setupReadTimerWithTimeout:currentRead->timeout];
				
				// Immediately read, if possible
				[self doReadData];
			}
		}
		else if (flags & kDisconnectAfterReads)
		{
		// 如果是读取后执行断开连接
			if (flags & kDisconnectAfterWrites)
			{
			// 如果是写入后执行断开连接
				if (([writeQueue count] == 0) && (currentWrite == nil))
				{
				// 如果写队列为空，且现在没有正在处理的写任务，就关闭连接
					[self closeWithError:nil];
				}
			}
			else
			{
			// 如果并不是写入后执行断开连接，则直接关闭
				[self closeWithError:nil];
			}
		}
		else if (flags & kSocketSecure)
		{
		// 
			[self flushSSLBuffers];
			
			// Edge case:
			// 
			// We just drained all data from the ssl buffers,
			// and all known data from the socket (socketFDBytesAvailable).
			// 
			// If we didn't get any data from this process,
			// then we may have reached the end of the TCP stream.
			// 
			// Be sure callbacks are enabled so we're notified about a disconnection.
			
			if ([preBuffer availableBytes] == 0)
			{
				if ([self usingCFStreamForTLS]) {
					// Callbacks never disabled
				}
				else {
					[self resumeReadSource];
				}
			}
		}
	}
}
// 读取ssl加密数据
- (void)flushSSLBuffers
{
	LogTrace();
	// 确认开启了secure
	NSAssert((flags & kSocketSecure), @"Cannot flush ssl buffers on non-secure socket");
	// 如果缓冲区不为空
	if ([preBuffer availableBytes] > 0)
	{
		// Only flush the ssl buffers if the prebuffer is empty.
		// This is to avoid growing the prebuffer inifinitely large.
		// 只在缓冲区为空时加载ssl buffer，防止缓冲区无限大
		return;
	}
	
	#if TARGET_OS_IPHONE
	
	if ([self usingCFStreamForTLS])
	{
	//如果使用了cfstream加密
		if ((flags & kSecureSocketHasBytesAvailable) && CFReadStreamHasBytesAvailable(readStream))
		{
		// 如果标记了有数据且读流也有数据
			LogVerbose(@"%@ - Flushing ssl buffers into prebuffer...", THIS_METHOD);
			// 准备4kb大小的空间
			CFIndex defaultBytesToRead = (1024 * 4);
			
			[preBuffer ensureCapacityForWrite:defaultBytesToRead];
			// 获取缓冲区的写指针
			uint8_t *buffer = [preBuffer writeBuffer];
			// 读取对应大小的数据到缓冲区
			CFIndex result = CFReadStreamRead(readStream, buffer, defaultBytesToRead);
			LogVerbose(@"%@ - CFReadStreamRead(): result = %i", THIS_METHOD, (int)result);
			
			if (result > 0)
			{
			// 读成功了则移动写指针
				[preBuffer didWrite:result];
			}
			// 去除加密socket有数据读的标记
			flags &= ~kSecureSocketHasBytesAvailable;
		}
		
		return;
	}
	
	#endif
	// 如果没有用cfstream，说明使用了ssl
	__block NSUInteger estimatedBytesAvailable = 0;
	
	dispatch_block_t updateEstimatedBytesAvailable = ^{
		
		// Figure out if there is any data available to be read
		// 
		// socketFDBytesAvailable        <- Number of encrypted bytes we haven't read from the bsd socket
		// [sslPreBuffer availableBytes] <- Number of encrypted bytes we've buffered from bsd socket
		// sslInternalBufSize            <- Number of decrypted bytes SecureTransport has buffered
		// 
		// We call the variable "estimated" because we don't know how many decrypted bytes we'll get
		// from the encrypted bytes in the sslPreBuffer.
		// However, we do know this is an upper bound on the estimation.
		// 估算数据，为socket的可读字节加上缓冲区的剩余可用空间再加上ssl可读字节
        estimatedBytesAvailable = self->socketFDBytesAvailable + [self->sslPreBuffer availableBytes];
		// 获取ssl可读字节
		size_t sslInternalBufSize = 0;
        SSLGetBufferedReadSize(self->sslContext, &sslInternalBufSize);
		
		estimatedBytesAvailable += sslInternalBufSize;
	};
	// 获取估算字节数
	updateEstimatedBytesAvailable();
	
	if (estimatedBytesAvailable > 0)
	{
	// 估算字节大于0
		LogVerbose(@"%@ - Flushing ssl buffers into prebuffer...", THIS_METHOD);
		
		BOOL done = NO;
		// 循环，直到读取到数据，或者预估字节重新算出来等于0，说明没数据可读
		do
		{
			LogVerbose(@"%@ - estimatedBytesAvailable = %lu", THIS_METHOD, (unsigned long)estimatedBytesAvailable);
			
			// Make sure there's enough room in the prebuffer
			// 确保缓冲区有足够大小
			[preBuffer ensureCapacityForWrite:estimatedBytesAvailable];
			
			// Read data into prebuffer
			// 获取写指针
			uint8_t *buffer = [preBuffer writeBuffer];
			size_t bytesRead = 0;
			// 读取ssl数据进缓冲区
			OSStatus result = SSLRead(sslContext, buffer, (size_t)estimatedBytesAvailable, &bytesRead);
			LogVerbose(@"%@ - read from secure socket = %u", THIS_METHOD, (unsigned)bytesRead);
			
			if (bytesRead > 0)
			{
			// 如果读取到字节，则移动写指针
				[preBuffer didWrite:bytesRead];
			}
			
			LogVerbose(@"%@ - prebuffer.length = %zu", THIS_METHOD, [preBuffer availableBytes]);
			
			if (result != noErr)
			{
			// 如果没错误则标记完成
				done = YES;
			}
			else
			{
			// 如果有错误，则重新计算估算字节
				updateEstimatedBytesAvailable();
			}
			
		} while (!done && estimatedBytesAvailable > 0);
	}
}
// 读取数据
- (void)doReadData
{
	LogTrace();
	
	// This method is called on the socketQueue.
	// It might be called directly, or via the readSource when data is available to be read.
	
	if ((currentRead == nil) || (flags & kReadsPaused))
	{
	// 如果没有当前正要读取的包，或者读取被暂停
		LogVerbose(@"No currentRead or kReadsPaused");
		
		// Unable to read at this time
		
		if (flags & kSocketSecure)
		{
		// 如果属于加密socket，则可能存在等待解密的数据，或者是断开连接的挥手数据，因此要尝试去读取
			// Here's the situation:
			// 
			// We have an established secure connection.
			// There may not be a currentRead, but there might be encrypted data sitting around for us.
			// When the user does get around to issuing a read, that encrypted data will need to be decrypted.
			// 
			// So why make the user wait?
			// We might as well get a head start on decrypting some data now.
			// 
			// The other reason we do this has to do with detecting a socket disconnection.
			// The SSL/TLS protocol has it's own disconnection handshake.
			// So when a secure socket is closed, a "goodbye" packet comes across the wire.
			// We want to make sure we read the "goodbye" packet so we can properly detect the TCP disconnection.
			// 读取ssl数据
			[self flushSSLBuffers];
		}
		
		if ([self usingCFStreamForTLS])
		{
		// 如果是用了CF流来加密，因为读流只会在有可用数据的时候触发一次，之后不会继续触发，直到调用读操作，因此可以忽视
			// CFReadStream only fires once when there is available data.
			// It won't fire again until we've invoked CFReadStreamRead.
		}
		else
		{
		// 如果读源被触发了，必须要暂停它，否则它可能会持续触发。但如果它没数据，那就可以让它继续监听
			// If the readSource is firing, we need to pause it
			// or else it will continue to fire over and over again.
			// 
			// If the readSource is not firing,
			// we want it to continue monitoring the socket.
			// 如果有数据，则暂停读源
			if (socketFDBytesAvailable > 0)
			{
				[self suspendReadSource];
			}
		}
		return;
	}
	// 到这儿说明没有被暂停且当前有待读取的包
	BOOL hasBytesAvailable = NO;
	unsigned long estimatedBytesAvailable = 0;
	
	if ([self usingCFStreamForTLS])
	{
	// 如果用了CF流
		#if TARGET_OS_IPHONE
		
		// Requested CFStream, rather than SecureTransport, for TLS (via GCDAsyncSocketUseCFStreamForTLS)
		
		estimatedBytesAvailable = 0;
		// 如果加密socket有可用字节且读流有可用字节，则标记存在可用字节
		if ((flags & kSecureSocketHasBytesAvailable) && CFReadStreamHasBytesAvailable(readStream))
			hasBytesAvailable = YES;
		else
			hasBytesAvailable = NO;
		
		#endif
	}
	else
	{
	// 没用CF流，则估算的可用字节设置为socketfd的可用字节
		estimatedBytesAvailable = socketFDBytesAvailable;
		
		if (flags & kSocketSecure)
		{
		// 如果是加密socket
			// There are 2 buffers to be aware of here.
			// 
			// We are using SecureTransport, a TLS/SSL security layer which sits atop TCP.
			// We issue a read to the SecureTranport API, which in turn issues a read to our SSLReadFunction.
			// Our SSLReadFunction then reads from the BSD socket and returns the encrypted data to SecureTransport.
			// SecureTransport then decrypts the data, and finally returns the decrypted data back to us.
			// 
			// The first buffer is one we create.
			// SecureTransport often requests small amounts of data.
			// This has to do with the encypted packets that are coming across the TCP stream.
			// But it's non-optimal to do a bunch of small reads from the BSD socket.
			// So our SSLReadFunction reads all available data from the socket (optimizing the sys call)
			// and may store excess in the sslPreBuffer.
			// 预估字节加上ssl缓冲区的可用字节
			estimatedBytesAvailable += [sslPreBuffer availableBytes];
			
			// The second buffer is within SecureTransport.
			// As mentioned earlier, there are encrypted packets coming across the TCP stream.
			// SecureTransport needs the entire packet to decrypt it.
			// But if the entire packet produces X bytes of decrypted data,
			// and we only asked SecureTransport for X/2 bytes of data,
			// it must store the extra X/2 bytes of decrypted data for the next read.
			// 
			// The SSLGetBufferedReadSize function will tell us the size of this internal buffer.
			// From the documentation:
			// 
			// "This function does not block or cause any low-level read operations to occur."
			// 再加上ssl内部的字节
			size_t sslInternalBufSize = 0;
			SSLGetBufferedReadSize(sslContext, &sslInternalBufSize);
			
			estimatedBytesAvailable += sslInternalBufSize;
		}
		// 判定是否有字节
		hasBytesAvailable = (estimatedBytesAvailable > 0);
	}
	
	if ((hasBytesAvailable == NO) && ([preBuffer availableBytes] == 0))
	{
		LogVerbose(@"No data available to read...");
		// 没有数据需要读取
		// No data available to read.
		
		if (![self usingCFStreamForTLS])
		{
			// Need to wait for readSource to fire and notify us of
			// available data in the socket's internal read buffer.
			// 如果没使用CF流，则需要恢复读源
			[self resumeReadSource];
		}
		return;
	}
	// 到这儿说明使用了CF流
	if (flags & kStartingReadTLS)
	{
		LogVerbose(@"Waiting for SSL/TLS handshake to complete");
		
		// The readQueue is waiting for SSL/TLS handshake to complete.
		// 如果已经开始读tls
		if (flags & kStartingWriteTLS)
		{
		// 如果已经开始写tls
			if ([self usingSecureTransportForTLS] && lastSSLHandshakeError == errSSLWouldBlock)
			{
				// We are in the process of a SSL Handshake.
				// We were waiting for incoming data which has just arrived.
				// 如果正在使用tls且上次握手错误为ssl即将阻塞，则继续握手操作
				[self ssl_continueSSLHandshake];
			}
		}
		else
		{
			// We are still waiting for the writeQueue to drain and start the SSL/TLS process.
			// We now know data is available to read.
			// 还没开始写tls
			if (![self usingCFStreamForTLS])
			{
				// Suspend the read source or else it will continue to fire nonstop.
				// 如果没使用CF流，则暂停读源
				[self suspendReadSource];
			}
		}
		
		return;
	}
	// 到这儿说明还没开始读ssl
	BOOL done        = NO;  // Completed read operation
	NSError *error   = nil; // Error occurred
	
	NSUInteger totalBytesReadForCurrentRead = 0;
	
	// 
	// STEP 1 - READ FROM PREBUFFER
	// 
	// 第一步，从缓冲区读
	if ([preBuffer availableBytes] > 0)
	{
		// There are 3 types of read packets:
		// 
		// 1) Read all available data.
		// 2) Read a specific length of data.
		// 3) Read up to a particular terminator.
		
		NSUInteger bytesToCopy;
		
		if (currentRead->term != nil)
		{
			// Read type #3 - read up to a terminator
			// 如果有终结符，则读取到终结符
			bytesToCopy = [currentRead readLengthForTermWithPreBuffer:preBuffer found:&done];
		}
		else
		{
			// Read type #1 or #2
			// 没有终结符，则将缓冲区数据读完
			bytesToCopy = [currentRead readLengthForNonTermWithHint:[preBuffer availableBytes]];
		}
		
		// Make sure we have enough room in the buffer for our read.
		// 确保有足够的区域去读取
		[currentRead ensureCapacityForAdditionalDataOfLength:bytesToCopy];
		
		// Copy bytes from prebuffer into packet buffer
		// 获取读包的指针位置
		uint8_t *buffer = (uint8_t *)[currentRead->buffer mutableBytes] + currentRead->startOffset +
		                                                                  currentRead->bytesDone;
		// 将数据拷贝到读包中
		memcpy(buffer, [preBuffer readBuffer], bytesToCopy);
		
		// Remove the copied bytes from the preBuffer
		// 标记缓冲区被读取
		[preBuffer didRead:bytesToCopy];
		
		LogVerbose(@"copied(%lu) preBufferLength(%zu)", (unsigned long)bytesToCopy, [preBuffer availableBytes]);
		
		// Update totals
		// 更新读取的字节数
		currentRead->bytesDone += bytesToCopy;
		totalBytesReadForCurrentRead += bytesToCopy;
		
		// Check to see if the read operation is done
		
		if (currentRead->readLength > 0)
		{
			// Read type #2 - read a specific length of data
			// 如果指定了读取的长度，则根据该长度判断是否读完
			done = (currentRead->bytesDone == currentRead->readLength);
		}
		else if (currentRead->term != nil)
		{
			// Read type #3 - read up to a terminator
			
			// Our 'done' variable was updated via the readLengthForTermWithPreBuffer:found: method
			// 如果是读取到终结符的模式
			if (!done && currentRead->maxLength > 0)
			{
				// We're not done and there's a set maxLength.
				// Have we reached that maxLength yet?
				// 如果没读完而且指定了最大长度
				if (currentRead->bytesDone >= currentRead->maxLength)
				{
				// 如果超过了最大长度，则报错
					error = [self readMaxedOutError];
				}
			}
		}
		else
		{
			// Read type #1 - read all available data
			// 
			// We're done as soon as
			// - we've read all available data (in prebuffer and socket)
			// - we've read the maxLength of read packet.
			// 如果是读取全部数据的模式，假设指定了最大长度且到达了，则表示完成
			done = ((currentRead->maxLength > 0) && (currentRead->bytesDone == currentRead->maxLength));
		}
		
	}
	
	// 
	// STEP 2 - READ FROM SOCKET
	// 
	//第二步，从socket里读
	// 判断是否读完了文件
	BOOL socketEOF = (flags & kSocketHasReadEOF) ? YES : NO;  // Nothing more to read via socket (end of file)
	// 判断是否在等待数据到来
	BOOL waiting   = !done && !error && !socketEOF && !hasBytesAvailable; // Ran out of data, waiting for more
	
	if (!done && !error && !socketEOF && hasBytesAvailable)
	{
	// 如果未完成，也未出错，文件未读完，且有数据可读
		NSAssert(([preBuffer availableBytes] == 0), @"Invalid logic");
		
		BOOL readIntoPreBuffer = NO;
		uint8_t *buffer = NULL;
		size_t bytesRead = 0;
		
		if (flags & kSocketSecure)
		{
		// 如果是加密的socket
			if ([self usingCFStreamForTLS])
			{
				#if TARGET_OS_IPHONE
				// 如果使用了CF流
				// Using CFStream, rather than SecureTransport, for TLS
				// 默认读取32kb字节
				NSUInteger defaultReadLength = (1024 * 32);
				// 获取实际合适的读取长度，并决定是否要读入缓冲区
				NSUInteger bytesToRead = [currentRead optimalReadLengthWithDefault:defaultReadLength
				                                                   shouldPreBuffer:&readIntoPreBuffer];
				
				// Make sure we have enough room in the buffer for our read.
				//
				// We are either reading directly into the currentRead->buffer,
				// or we're reading into the temporary preBuffer.
				
				if (readIntoPreBuffer)
				{
				// 如果需要读到缓冲区内，则对缓冲区调用确保读取大小的方法
					[preBuffer ensureCapacityForWrite:bytesToRead];
					// 获取写指针
					buffer = [preBuffer writeBuffer];
				}
				else
				{
				// 不需要读到缓冲区。则对当前数据区确保额外的空间去读取数据
					[currentRead ensureCapacityForAdditionalDataOfLength:bytesToRead];
					// 获取写指针
					buffer = (uint8_t *)[currentRead->buffer mutableBytes]
					       + currentRead->startOffset
					       + currentRead->bytesDone;
				}
				
				// Read data into buffer
				// 读取数据
				CFIndex result = CFReadStreamRead(readStream, buffer, (CFIndex)bytesToRead);
				LogVerbose(@"CFReadStreamRead(): result = %i", (int)result);
				// 根据读取数据长度做不同处理
				if (result < 0)
				{
					error = (__bridge_transfer NSError *)CFReadStreamCopyError(readStream);
				}
				else if (result == 0)
				{
					socketEOF = YES;
				}
				else
				{
					waiting = YES;
					bytesRead = (size_t)result;
				}
				
				// We only know how many decrypted bytes were read.
				// The actual number of bytes read was likely more due to the overhead of the encryption.
				// So we reset our flag, and rely on the next callback to alert us of more data.
				// 由于只能知道解密的数据读取了多少，实际加密的数据读取的量是不知道的，因此只能等下一次回调告知更多的数据
				flags &= ~kSecureSocketHasBytesAvailable;
				
				#endif
			}
			else
			{
			// 使用TLS的加密传输
				// Using SecureTransport for TLS
				//
				// We know:
				// - how many bytes are available on the socket
				// - how many encrypted bytes are sitting in the sslPreBuffer
				// - how many decypted bytes are sitting in the sslContext
				//
				// But we do NOT know:
				// - how many encypted bytes are sitting in the sslContext
				//
				// So we play the regular game of using an upper bound instead.
				// 知道socket上有多少可读数据，ssl缓冲区有多少加密数据，ssl上下文有多少解密数据，但不知道对应的是多少加密数据被放入了ssl上下文后解密，因此取一个上限值去读取
				NSUInteger defaultReadLength = (1024 * 32);
				
				if (defaultReadLength < estimatedBytesAvailable) {
					// 如果默认读取长度小于预估的长度，则再加上16kb字节
					defaultReadLength = estimatedBytesAvailable + (1024 * 16);
				}
				// 根据当前数据区大小决定修正要读取的长度，以及是否需要用缓冲区
				NSUInteger bytesToRead = [currentRead optimalReadLengthWithDefault:defaultReadLength
				                                                   shouldPreBuffer:&readIntoPreBuffer];
				
				if (bytesToRead > SIZE_MAX) { // NSUInteger may be bigger than size_t
				// 如果超过了类型的上限，那再次修正
					bytesToRead = SIZE_MAX;
				}
				
				// Make sure we have enough room in the buffer for our read.
				//
				// We are either reading directly into the currentRead->buffer,
				// or we're reading into the temporary preBuffer.
				
				if (readIntoPreBuffer)
				{
				// 如果要读到缓冲区，则确保缓冲区的大小并获取读写指针
					[preBuffer ensureCapacityForWrite:bytesToRead];
					
					buffer = [preBuffer writeBuffer];
				}
				else
				{
				// 如果直接读取到数据区，则确保数据区的大小并获取写指针
					[currentRead ensureCapacityForAdditionalDataOfLength:bytesToRead];
					
					buffer = (uint8_t *)[currentRead->buffer mutableBytes]
					       + currentRead->startOffset
					       + currentRead->bytesDone;
				}
				
				// The documentation from Apple states:
				// 
				//     "a read operation might return errSSLWouldBlock,
				//      indicating that less data than requested was actually transferred"
				// 
				// However, starting around 10.7, the function will sometimes return noErr,
				// even if it didn't read as much data as requested. So we need to watch out for that.
				
				OSStatus result;
				do
				{
				// 获取本次循环的读指针位置
					void *loop_buffer = buffer + bytesRead;
					// 获取循环剩余需要读的长度
					size_t loop_bytesToRead = (size_t)bytesToRead - bytesRead;
					// 声明本次循环读取的长度
					size_t loop_bytesRead = 0;
					// 读取数据
					result = SSLRead(sslContext, loop_buffer, loop_bytesToRead, &loop_bytesRead);
					LogVerbose(@"read from secure socket = %u", (unsigned)loop_bytesRead);
					
					bytesRead += loop_bytesRead;
					// 如果没报错且还未全部读取完
				} while ((result == noErr) && (bytesRead < bytesToRead));
				
				
				if (result != noErr)
				{
				// 如果报错了
					if (result == errSSLWouldBlock)
					// 如果结果是ssl阻塞，则标记正在等待
						waiting = YES;
					else
					{
					// 如果是其他原因
						if (result == errSSLClosedGraceful || result == errSSLClosedAbort)
						{
						// 如果结果是ssl关闭了导致的，说明读完了
							// We've reached the end of the stream.
							// Handle this the same way we would an EOF from the socket.
							socketEOF = YES;
							sslErrCode = result;
						}
						else
						{
						// 否则创建错误对象
							error = [self sslError:result];
						}
					}
					// It's possible that bytesRead > 0, even if the result was errSSLWouldBlock.
					// This happens when the SSLRead function is able to read some data,
					// but not the entire amount we requested.
					
					if (bytesRead <= 0)
					{
					// 修正读取的长度
						bytesRead = 0;
					}
				}
				
				// Do not modify socketFDBytesAvailable.
				// It will be updated via the SSLReadFunction().
			}
		}
		else
		{
			// Normal socket operation
			// 非加密的socket
			NSUInteger bytesToRead;
			
			// There are 3 types of read packets:
			//
			// 1) Read all available data.
			// 2) Read a specific length of data.
			// 3) Read up to a particular terminator.
			
			if (currentRead->term != nil)
			{
				// Read type #3 - read up to a terminator
				// 如果是读取直到终结符的场景，获取需要读取的长度，并获取是否需要缓冲区
				bytesToRead = [currentRead readLengthForTermWithHint:estimatedBytesAvailable
				                                     shouldPreBuffer:&readIntoPreBuffer];
			}
			else
			{
				// Read type #1 or #2
				// 如果是读取指定长度或全部读完的场景，获取读取的长度
				bytesToRead = [currentRead readLengthForNonTermWithHint:estimatedBytesAvailable];
			}
			
			if (bytesToRead > SIZE_MAX) { // NSUInteger may be bigger than size_t (read param 3)
			// 修正溢出
				bytesToRead = SIZE_MAX;
			}
			
			// Make sure we have enough room in the buffer for our read.
			//
			// We are either reading directly into the currentRead->buffer,
			// or we're reading into the temporary preBuffer.
			
			if (readIntoPreBuffer)
			{
			// 如果需要缓冲区，则确保缓冲区足够的大小，并获取写指针
				[preBuffer ensureCapacityForWrite:bytesToRead];
				
				buffer = [preBuffer writeBuffer];
			}
			else
			{
			// 不需要缓冲区，则确保当前的数据区的大小
				[currentRead ensureCapacityForAdditionalDataOfLength:bytesToRead];
				// 算出写指针的位置
				buffer = (uint8_t *)[currentRead->buffer mutableBytes]
				       + currentRead->startOffset
				       + currentRead->bytesDone;
			}
			
			// Read data into buffer
			// 获取socketfd
			int socketFD = (socket4FD != SOCKET_NULL) ? socket4FD : (socket6FD != SOCKET_NULL) ? socket6FD : socketUN;
			// 读数据到写指针中写入数据
			ssize_t result = read(socketFD, buffer, (size_t)bytesToRead);
			LogVerbose(@"read from socket = %i", (int)result);
			
			if (result < 0)
			{
			// 如果出现了错误
				if (errno == EWOULDBLOCK)
				// 如果是被阻塞，标记等待
					waiting = YES;
				else
				// 其他错误，创建错误对象
					error = [self errorWithErrno:errno reason:@"Error in read() function"];
				
				// 设置socketfd可用字节为0
				socketFDBytesAvailable = 0;
			}
			else if (result == 0)
			{
			// 读完了，标记，设置socketfd可用字节为0
				socketEOF = YES;
				socketFDBytesAvailable = 0;
			}
			else
			{
			// 没读完，记录读取的长度
				bytesRead = result;
				
				if (bytesRead < bytesToRead)
				{
					// The read returned less data than requested.
					// This means socketFDBytesAvailable was a bit off due to timing,
					// because we read from the socket right when the readSource event was firing.
					// 说明还有部分数据未到达，标记socketfd可用字节为0
					socketFDBytesAvailable = 0;
				}
				else
				{
					if (socketFDBytesAvailable <= bytesRead)
						// 说明socketfd全部读完了，并且实际读取的数据可能比当时计算的要更长
						socketFDBytesAvailable = 0;
					else
						// 没全部读完，则计算剩余长度
						socketFDBytesAvailable -= bytesRead;
				}
				
				if (socketFDBytesAvailable == 0)
				{
				// socketfd读完了，则标记等待
					waiting = YES;
				}
			}
		}
		
		if (bytesRead > 0)
		{
			// Check to see if the read operation is done
			// 读到了数据
			if (currentRead->readLength > 0)
			{
				// Read type #2 - read a specific length of data
				// 
				// Note: We should never be using a prebuffer when we're reading a specific length of data.
				// 指定了读取长度
				NSAssert(readIntoPreBuffer == NO, @"Invalid logic");
				// 计算当前读包的长度属性，并判断是否完成
				currentRead->bytesDone += bytesRead;
				totalBytesReadForCurrentRead += bytesRead;
				
				done = (currentRead->bytesDone == currentRead->readLength);
			}
			else if (currentRead->term != nil)
			{
				// Read type #3 - read up to a terminator
				// 如果当前是读取到终结符才停止的模式
				if (readIntoPreBuffer)
				{
					// We just read a big chunk of data into the preBuffer
					// 如果用到了缓冲区，则标记缓冲区使用的长度
					[preBuffer didWrite:bytesRead];
					LogVerbose(@"read data into preBuffer - preBuffer.length = %zu", [preBuffer availableBytes]);
					
					// Search for the terminating sequence
					// 计算需要拷贝的数据长度
					NSUInteger bytesToCopy = [currentRead readLengthForTermWithPreBuffer:preBuffer found:&done];
					LogVerbose(@"copying %lu bytes from preBuffer", (unsigned long)bytesToCopy);
					
					// Ensure there's room on the read packet's buffer
					// 确保读包的空间大小
					[currentRead ensureCapacityForAdditionalDataOfLength:bytesToCopy];
					
					// Copy bytes from prebuffer into read buffer
					// 获取读包的写指针
					uint8_t *readBuf = (uint8_t *)[currentRead->buffer mutableBytes] + currentRead->startOffset
					                                                                 + currentRead->bytesDone;
					// 拷贝缓冲区数据到读包里
					memcpy(readBuf, [preBuffer readBuffer], bytesToCopy);
					// 移动缓冲区读指针
					// Remove the copied bytes from the prebuffer
					[preBuffer didRead:bytesToCopy];
					LogVerbose(@"preBuffer.length = %zu", [preBuffer availableBytes]);
					// 更新完成的数据
					// Update totals
					currentRead->bytesDone += bytesToCopy;
					totalBytesReadForCurrentRead += bytesToCopy;
					
					// Our 'done' variable was updated via the readLengthForTermWithPreBuffer:found: method above
				}
				else
				{
					// We just read a big chunk of data directly into the packet's buffer.
					// We need to move any overflow into the prebuffer.
					// 没有用到缓冲区，但需要判断是否有溢出的数据
					NSInteger overflow = [currentRead searchForTermAfterPreBuffering:bytesRead];
					
					if (overflow == 0)
					{
						// Perfect match!
						// Every byte we read stays in the read buffer,
						// and the last byte we read was the last byte of the term.
						// 没有溢出数据，则更改长度属性，标记完成
						currentRead->bytesDone += bytesRead;
						totalBytesReadForCurrentRead += bytesRead;
						done = YES;
					}
					else if (overflow > 0)
					{
						// The term was found within the data that we read,
						// and there are extra bytes that extend past the end of the term.
						// We need to move these excess bytes out of the read packet and into the prebuffer.
						// 有溢出数据
						NSInteger underflow = bytesRead - overflow;
						
						// Copy excess data into preBuffer
						
						LogVerbose(@"copying %ld overflow bytes into preBuffer", (long)overflow);
						// 将溢出数据拷贝到缓冲区并更新长度
						[preBuffer ensureCapacityForWrite:overflow];
						
						uint8_t *overflowBuffer = buffer + underflow;
						memcpy([preBuffer writeBuffer], overflowBuffer, overflow);
						
						[preBuffer didWrite:overflow];
						LogVerbose(@"preBuffer.length = %zu", [preBuffer availableBytes]);
						
						// Note: The completeCurrentRead method will trim the buffer for us.
						
						currentRead->bytesDone += underflow;
						totalBytesReadForCurrentRead += underflow;
						done = YES;
					}
					else
					{
						// The term was not found within the data that we read.
						// 没有发现终结符，先更新长度
						currentRead->bytesDone += bytesRead;
						totalBytesReadForCurrentRead += bytesRead;
						done = NO;
					}
				}
				
				if (!done && currentRead->maxLength > 0)
				{
					// We're not done and there's a set maxLength.
					// Have we reached that maxLength yet?
					// 如果没完成而且设置过最大长度
					if (currentRead->bytesDone >= currentRead->maxLength)
					{
					// 如果超过最大长度则报错
						error = [self readMaxedOutError];
					}
				}
			}
			else
			{
				// Read type #1 - read all available data
				// 读取全部数据的模式
				if (readIntoPreBuffer)
				{
					// We just read a chunk of data into the preBuffer
					// 如果用到了缓冲区则移动写指针
					[preBuffer didWrite:bytesRead];
					
					// Now copy the data into the read packet.
					// 
					// Recall that we didn't read directly into the packet's buffer to avoid
					// over-allocating memory since we had no clue how much data was available to be read.
					// 
					// Ensure there's room on the read packet's buffer
					// 确保读包的空间
					[currentRead ensureCapacityForAdditionalDataOfLength:bytesRead];
					
					// Copy bytes from prebuffer into read buffer
					// 获取读包的写指针
					uint8_t *readBuf = (uint8_t *)[currentRead->buffer mutableBytes] + currentRead->startOffset
					                                                                 + currentRead->bytesDone;
					// 拷贝数据到读包中
					memcpy(readBuf, [preBuffer readBuffer], bytesRead);
					
					// Remove the copied bytes from the prebuffer
					// 移动缓冲区的读指针
					[preBuffer didRead:bytesRead];
					
					// Update totals
					currentRead->bytesDone += bytesRead;
					totalBytesReadForCurrentRead += bytesRead;
				}
				else
				{
				// 没有用到缓冲区，直接更新长度
					currentRead->bytesDone += bytesRead;
					totalBytesReadForCurrentRead += bytesRead;
				}
				
				done = YES;
			}
			
		} // if (bytesRead > 0)
		
	} // if (!done && !error && !socketEOF && hasBytesAvailable)
	
	
	if (!done && currentRead->readLength == 0 && currentRead->term == nil)
	{
		// Read type #1 - read all available data
		// 
		// We might arrive here if we read data from the prebuffer but not from the socket.
		// 如果是读取全部数据的模式，只要读到数据就算完成
		done = (totalBytesReadForCurrentRead > 0);
	}
	
	// Check to see if we're done, or if we've made progress
	
	if (done)
	{
	// 如果完成了，标记
		[self completeCurrentRead];
		
		if (!error && (!socketEOF || [preBuffer availableBytes] > 0))
		{
		// 如果没报错也没有全部读完，则尝试读下一个包
			[self maybeDequeueRead];
		}
	}
	else if (totalBytesReadForCurrentRead > 0)
	{
		// We're not done read type #2 or #3 yet, but we have read in some bytes
		//
		// We ensure that `waiting` is set in order to resume the readSource (if it is suspended). It is
		// possible to reach this point and `waiting` not be set, if the current read's length is
		// sufficiently large. In that case, we may have read to some upperbound successfully, but
		// that upperbound could be smaller than the desired length.
		// 如果读到过数据，模式不是读取所有数据，则标记等待
		waiting = YES;
// 回调外部告知读取了部分数据
		__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;
		
		if (delegateQueue && [theDelegate respondsToSelector:@selector(socket:didReadPartialDataOfLength:tag:)])
		{
			long theReadTag = currentRead->tag;
			
			dispatch_async(delegateQueue, ^{ @autoreleasepool {
				
				[theDelegate socket:self didReadPartialDataOfLength:totalBytesReadForCurrentRead tag:theReadTag];
			}});
		}
	}
	
	// Check for errors
	
	if (error)
	{
	// 如果有错误则关闭
		[self closeWithError:error];
	}
	else if (socketEOF)
	{
	// 如果读完了则做相应处理
		[self doReadEOF];
	}
	else if (waiting)
	{
	// 如果在等待后面的数据
		if (![self usingCFStreamForTLS])
		{
		// 如果没有用CF流
			// Monitor the socket for readability (if we're not already doing so)
			// 恢复读源
			[self resumeReadSource];
		}
	}
	
	// Do not add any code here without first adding return statements in the error cases above.
}
// 读到文件末尾
- (void)doReadEOF
{
	LogTrace();
	
	// This method may be called more than once.
	// If the EOF is read while there is still data in the preBuffer,
	// then this method may be called continually after invocations of doReadData to see if it's time to disconnect.
	// 添加标记
	flags |= kSocketHasReadEOF;
	
	if (flags & kSocketSecure)
	{
		// If the SSL layer has any buffered data, flush it into the preBuffer now.
		// 如果是加密数据，则处理ssl缓冲区数据
		[self flushSSLBuffers];
	}
	
	BOOL shouldDisconnect = NO;
	NSError *error = nil;
	
	if ((flags & kStartingReadTLS) || (flags & kStartingWriteTLS))
	{
	// 如果是开始读或写TLS的状态
		// We received an EOF during or prior to startTLS.
		// The SSL/TLS handshake is now impossible, so this is an unrecoverable situation.
		
		shouldDisconnect = YES;
		// 如果是使用了TLS传输遇到了文件终结符，则应该断开连接
		if ([self usingSecureTransportForTLS])
		{
			error = [self sslError:errSSLClosedAbort];
		}
	}
	else if (flags & kReadStreamClosed)
	{
		// The preBuffer has already been drained.
		// The config allows half-duplex connections.
		// We've previously checked the socket, and it appeared writeable.
		// So we marked the read stream as closed and notified the delegate.
		// 
		// As per the half-duplex contract, the socket will be closed when a write fails,
		// or when the socket is manually closed.
		// 读流关闭的状态，因为还可以允许写完未传输完的数据，而且之前已经检查过一次（因此才会处于读流关闭的状态），所以不用断开连接
		shouldDisconnect = NO;
	}
	else if ([preBuffer availableBytes] > 0)
	{
		LogVerbose(@"Socket reached EOF, but there is still data available in prebuffer");
		
		// Although we won't be able to read any more data from the socket,
		// there is existing data that has been prebuffered that we can read.
		// 如果缓冲区还有数据则不应该断开连接
		shouldDisconnect = NO;
	}
	else if (config & kAllowHalfDuplexConnection)
	{
		// We just received an EOF (end of file) from the socket's read stream.
		// This means the remote end of the socket (the peer we're connected to)
		// has explicitly stated that it will not be sending us any more data.
		// 
		// Query the socket to see if it is still writeable. (Perhaps the peer will continue reading data from us)
		// 远端已经告知没有数据，但可能还需要读取这一端写入的数据
		// 获取socketfd
		int socketFD = (socket4FD != SOCKET_NULL) ? socket4FD : (socket6FD != SOCKET_NULL) ? socket6FD : socketUN;
		// 检测fd是否仍旧可写
		struct pollfd pfd[1];
		pfd[0].fd = socketFD;
		pfd[0].events = POLLOUT;
		pfd[0].revents = 0;
		
		poll(pfd, 1, 0);
		
		if (pfd[0].revents & POLLOUT)
		{
			// Socket appears to still be writeable
			// socket仍旧可写，则不断开连接，但标记读流关闭
			shouldDisconnect = NO;
			flags |= kReadStreamClosed;
			
			// Notify the delegate that we're going half-duplex
			// 通知外部代理关闭了读流
			__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;

			if (delegateQueue && [theDelegate respondsToSelector:@selector(socketDidCloseReadStream:)])
			{
				dispatch_async(delegateQueue, ^{ @autoreleasepool {
					
					[theDelegate socketDidCloseReadStream:self];
				}});
			}
		}
		else
		{
		// socket已经不可写，应该断开连接
			shouldDisconnect = YES;
		}
	}
	else
	{
	// 其他情况，应该断开连接
		shouldDisconnect = YES;
	}
	
	
	if (shouldDisconnect)
	{
	// 如果判断需要断开连接
		if (error == nil)
		{
		// 如果没错误
			if ([self usingSecureTransportForTLS])
			{
			// 如果使用了TLS加密
				if (sslErrCode != noErr && sslErrCode != errSSLClosedGraceful)
				{
				// 如果有ssl错误，则创建ssl错误对象
					error = [self sslError:sslErrCode];
				}
				else
				{
				// 否则创建错误对象为关闭连接
					error = [self connectionClosedError];
				}
			}
			else
			{
			// 没使用TLS加密，设置错误对象为关闭连接
				error = [self connectionClosedError];
			}
		}
		// 关闭连接
		[self closeWithError:error];
	}
	else
	{
	// 不需要关闭连接
		if (![self usingCFStreamForTLS])
		{
			// Suspend the read source (if needed)
			// 如果没使用CF流，则暂停读源
			[self suspendReadSource];
		}
	}
}
// 完成当前的读包
- (void)completeCurrentRead
{
	LogTrace();
	
	NSAssert(currentRead, @"Trying to complete current read when there is no current read.");
	
	
	NSData *result = nil;
	
	if (currentRead->bufferOwner)
	{
	// 读包是我们代表用户创建的
		// We created the buffer on behalf of the user.
		// Trim our buffer to be the proper size.
		// 缩减读包多余的长度
		[currentRead->buffer setLength:currentRead->bytesDone];
		
		result = currentRead->buffer;
	}
	else
	{
		// We did NOT create the buffer.
		// The buffer is owned by the caller.
		// Only trim the buffer if we had to increase its size.
		// 读包是调用方创建的，因此只有在已经增加了大小的情况下才缩减包
		if ([currentRead->buffer length] > currentRead->originalBufferLength)
		{
		// 如果当前长度大于原本的长度，则重新设置大小
			NSUInteger readSize = currentRead->startOffset + currentRead->bytesDone;
			NSUInteger origSize = currentRead->originalBufferLength;
			
			NSUInteger buffSize = MAX(readSize, origSize);
			
			[currentRead->buffer setLength:buffSize];
		}
		// 获取根据偏移量截取的数据
		uint8_t *buffer = (uint8_t *)[currentRead->buffer mutableBytes] + currentRead->startOffset;
		
		result = [NSData dataWithBytesNoCopy:buffer length:currentRead->bytesDone freeWhenDone:NO];
	}
	
	__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;
// 通知外部代理读到了数据
	if (delegateQueue && [theDelegate respondsToSelector:@selector(socket:didReadData:withTag:)])
	{
		GCDAsyncReadPacket *theRead = currentRead; // Ensure currentRead retained since result may not own buffer
		
		dispatch_async(delegateQueue, ^{ @autoreleasepool {
			
			[theDelegate socket:self didReadData:result withTag:theRead->tag];
		}});
	}
	
	[self endCurrentRead];
}
// 结束当前读操作
- (void)endCurrentRead
{
	if (readTimer)
	{
		// 如果有读取的计时器，则清空
		dispatch_source_cancel(readTimer);
		readTimer = NULL;
	}
	
	currentRead = nil;
}
// 设置读的计时器
- (void)setupReadTimerWithTimeout:(NSTimeInterval)timeout
{
	if (timeout >= 0.0)
	{
	// 创建计时器
		readTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, socketQueue);
		
		__weak GCDAsyncSocket *weakSelf = self;
		
		dispatch_source_set_event_handler(readTimer, ^{ @autoreleasepool {
		#pragma clang diagnostic push
		#pragma clang diagnostic warning "-Wimplicit-retain-self"
			
			__strong GCDAsyncSocket *strongSelf = weakSelf;
			if (strongSelf == nil) return_from_block;
			// 执行读超时处理
			[strongSelf doReadTimeout];
			
		#pragma clang diagnostic pop
		}});
		
		#if !OS_OBJECT_USE_OBJC
		dispatch_source_t theReadTimer = readTimer;
		
		// 设置取消计时器时释放
		dispatch_source_set_cancel_handler(readTimer, ^{
		#pragma clang diagnostic push
		#pragma clang diagnostic warning "-Wimplicit-retain-self"
			
			LogVerbose(@"dispatch_release(readTimer)");
			dispatch_release(theReadTimer);
			
		#pragma clang diagnostic pop
		});
		#endif
		// 设置计时器
		dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
		
		dispatch_source_set_timer(readTimer, tt, DISPATCH_TIME_FOREVER, 0);
		dispatch_resume(readTimer);
	}
}
// 处理读超时
- (void)doReadTimeout
{
	// This is a little bit tricky.
	// Ideally we'd like to synchronously query the delegate about a timeout extension.
	// But if we do so synchronously we risk a possible deadlock.
	// So instead we have to do so asynchronously, and callback to ourselves from within the delegate block.
	// 标识读暂停
	flags |= kReadsPaused;
	
	__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;

	if (delegateQueue && [theDelegate respondsToSelector:@selector(socket:shouldTimeoutReadWithTag:elapsed:bytesDone:)])
	{
	// 代理实现了是否应该超时的方法
		GCDAsyncReadPacket *theRead = currentRead;
		
		dispatch_async(delegateQueue, ^{ @autoreleasepool {
			// 获取续的时长
			NSTimeInterval timeoutExtension = 0.0;
			
			timeoutExtension = [theDelegate socket:self shouldTimeoutReadWithTag:theRead->tag
			                                                             elapsed:theRead->timeout
			                                                           bytesDone:theRead->bytesDone];
			
            dispatch_async(self->socketQueue, ^{ @autoreleasepool {
				// 处理续时长
				[self doReadTimeoutWithExtension:timeoutExtension];
			}});
		}});
	}
	else
	{
	// 代理没实现，则处理不续时长
		[self doReadTimeoutWithExtension:0.0];
	}
}
// 处理超时，并续时长
- (void)doReadTimeoutWithExtension:(NSTimeInterval)timeoutExtension
{
	if (currentRead)
	{
	// 如果当前读操作的包存在
		if (timeoutExtension > 0.0)
		{
		// 如果需要续时长
			currentRead->timeout += timeoutExtension;
			
			// Reschedule the timer
			// 重新设置对应时长的计时器
			dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutExtension * NSEC_PER_SEC));
			dispatch_source_set_timer(readTimer, tt, DISPATCH_TIME_FOREVER, 0);
			
			// Unpause reads, and continue
			// 取消暂停的标记，继续读数据
			flags &= ~kReadsPaused;
			[self doReadData];
		}
		else
		{
			// 如果不需要续时长，则关闭连接
			LogVerbose(@"ReadTimeout");
			
			[self closeWithError:[self readTimeoutError]];
		}
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Writing
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// 写数据，并传入超时时长、tag
- (void)writeData:(NSData *)data withTimeout:(NSTimeInterval)timeout tag:(long)tag
{
// 如果没数据则返回
	if ([data length] == 0) return;
	// 初始化写操作包
	GCDAsyncWritePacket *packet = [[GCDAsyncWritePacket alloc] initWithData:data timeout:timeout tag:tag];
	
	dispatch_async(socketQueue, ^{ @autoreleasepool {
		
		LogTrace();
		
        if ((self->flags & kSocketStarted) && !(self->flags & kForbidReadsWrites))
		{
		// 如果socket已经开始，且没有忽略读写操作
		// 往写队列添加写操作包，并从写队列中尝试取一个操作包处理
            [self->writeQueue addObject:packet];
			[self maybeDequeueWrite];
		}
	}});
	
	// Do not rely on the block being run in order to release the packet,
	// as the queue might get released without the block completing.
}
// 获取当前写操作的进度、tag、已完成字节数和总字节数
- (float)progressOfWriteReturningTag:(long *)tagPtr bytesDone:(NSUInteger *)donePtr total:(NSUInteger *)totalPtr
{
	__block float result = 0.0F;
	
	dispatch_block_t block = ^{
		
        if (!self->currentWrite || ![self->currentWrite isKindOfClass:[GCDAsyncWritePacket class]])
		{
			// We're not writing anything right now.
			// 如果现在没有处理的写操作，则返回
			if (tagPtr != NULL)   *tagPtr = 0;
			if (donePtr != NULL)  *donePtr = 0;
			if (totalPtr != NULL) *totalPtr = 0;
			
			result = NAN;
		}
		else
		{
		// 将正在处理的写操作对应的值返回
            NSUInteger done = self->currentWrite->bytesDone;
            NSUInteger total = [self->currentWrite->buffer length];
			
            if (tagPtr != NULL)   *tagPtr = self->currentWrite->tag;
			if (donePtr != NULL)  *donePtr = done;
			if (totalPtr != NULL) *totalPtr = total;
			
			result = (float)done / (float)total;
		}
	};
	// 保证在socket队列上处理
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	return result;
}

/**
 * Conditionally starts a new write.
 * 
 * It is called when:
 * - a user requests a write
 * - after a write request has finished (to handle the next request)
 * - immediately after the socket opens to handle any pending requests
 * 
 * This method also handles auto-disconnect post read/write completion.
**/
// 尝试处理队列中的写操作
- (void)maybeDequeueWrite
{
	LogTrace();
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	
	// If we're not currently processing a write AND we have an available write stream
	if ((currentWrite == nil) && (flags & kConnected))
	{
	// 如果当前没有正在处理的写操作包，并且socket已经连接上
		if ([writeQueue count] > 0)
		{
			// Dequeue the next object in the write queue
			// 如果写队列有内容
			// 获取写队列中的第一个包，并移除
			currentWrite = [writeQueue objectAtIndex:0];
			[writeQueue removeObjectAtIndex:0];
			
			
			if ([currentWrite isKindOfClass:[GCDAsyncSpecialPacket class]])
			{
				// 如果这是一个特殊包
				LogVerbose(@"Dequeued GCDAsyncSpecialPacket");
				
				// Attempt to start TLS
				// 尝试进行TLS加密
				flags |= kStartingWriteTLS;
				
				// This method won't do anything unless both kStartingReadTLS and kStartingWriteTLS are set
				[self maybeStartTLS];
			}
			else
			{
				LogVerbose(@"Dequeued GCDAsyncWritePacket");
				// 这不是特殊包lqa
				// Setup write timer (if needed)
				// 设置写的计时器
				[self setupWriteTimerWithTimeout:currentWrite->timeout];
				
				// Immediately write, if possible
				// 开始写数据
				[self doWriteData];
			}
		}
		else if (flags & kDisconnectAfterWrites)
		{
		// 如果设置了写完所有数据才断开连接
			if (flags & kDisconnectAfterReads)
			{
			// 如果设置了读完所有数据才断开连接
				if (([readQueue count] == 0) && (currentRead == nil))
				{
				// 如果读队列空了并且当前没有正在处理的读操作包，则断开连接
					[self closeWithError:nil];
				}
			}
			else
			{
			// 如果没设置读完所有数据才断开连接，则直接断开连接
				[self closeWithError:nil];
			}
		}
	}
}
// 进行写操作
- (void)doWriteData
{
	LogTrace();
	
	// This method is called by the writeSource via the socketQueue
	
	if ((currentWrite == nil) || (flags & kWritesPaused))
	{
	// 如果当前没有正在处理的写操作包，或者写操作被暂停了
		LogVerbose(@"No currentWrite or kWritesPaused");
		
		// Unable to write at this time
		
		if ([self usingCFStreamForTLS])
		{
		// 如果使用了CF流，则不处理
			// CFWriteStream only fires once when there is available data.
			// It won't fire again until we've invoked CFWriteStreamWrite.
		}
		else
		{
			// If the writeSource is firing, we need to pause it
			// or else it will continue to fire over and over again.
			// 如果没使用CF流，需要暂停
			if (flags & kSocketCanAcceptBytes)
			{
			// 如果socket可以接收数据，则暂停写源
				[self suspendWriteSource];
			}
		}
		return;
	}
	// 当前有正在处理的写操作包且写操作没被暂停
	if (!(flags & kSocketCanAcceptBytes))
	{
	// 如果socket无法接收字节
		LogVerbose(@"No space available to write...");
		
		// No space available to write.
		
		if (![self usingCFStreamForTLS])
		{
		// 如果没使用CF流，则需要恢复写源
			// Need to wait for writeSource to fire and notify us of
			// available space in the socket's internal write buffer.
			
			[self resumeWriteSource];
		}
		return;
	}
	// socket可以接收字节
	if (flags & kStartingWriteTLS)
	{
	// 如果已经开始写TLS
		LogVerbose(@"Waiting for SSL/TLS handshake to complete");
		
		// The writeQueue is waiting for SSL/TLS handshake to complete.
		
		if (flags & kStartingReadTLS)
		{
		// 如果已经开始读TLS
			if ([self usingSecureTransportForTLS] && lastSSLHandshakeError == errSSLWouldBlock)
			{
			// 如果使用了TLS加密且上一次握手失败的原因是ssl被阻塞
				// We are in the process of a SSL Handshake.
				// We were waiting for available space in the socket's internal OS buffer to continue writing.
			// 继续ssl握手
				[self ssl_continueSSLHandshake];
			}
		}
		else
		{
		// 如果没有开始读ssl
			// We are still waiting for the readQueue to drain and start the SSL/TLS process.
			// We now know we can write to the socket.
			
			if (![self usingCFStreamForTLS])
			{
				// Suspend the write source or else it will continue to fire nonstop.
				// 如果没有使用CF流，则需要暂停写源
				[self suspendWriteSource];
			}
		}
		
		return;
	}
	// 如果还没开始写TLS
	// Note: This method is not called if currentWrite is a GCDAsyncSpecialPacket (startTLS packet)
	
	BOOL waiting = NO;
	NSError *error = nil;
	size_t bytesWritten = 0;
	
	if (flags & kSocketSecure)
	{
	// 如果socket是加密的
		if ([self usingCFStreamForTLS])
		{
		// 如果使用了CF流
			#if TARGET_OS_IPHONE
			
			// 
			// Writing data using CFStream (over internal TLS)
			// 
			// 获取写指针
			const uint8_t *buffer = (const uint8_t *)[currentWrite->buffer bytes] + currentWrite->bytesDone;
			// 获取当前写操作包剩余要写的长度
			NSUInteger bytesToWrite = [currentWrite->buffer length] - currentWrite->bytesDone;
			
			if (bytesToWrite > SIZE_MAX) // NSUInteger may be bigger than size_t (write param 3)
			{
			// 修正要写的数据长度
				bytesToWrite = SIZE_MAX;
			}
		// 写数据
			CFIndex result = CFWriteStreamWrite(writeStream, buffer, (CFIndex)bytesToWrite);
			LogVerbose(@"CFWriteStreamWrite(%lu) = %li", (unsigned long)bytesToWrite, result);
		
			if (result < 0)
			{
			// 发生了错误，则创建错误对象
				error = (__bridge_transfer NSError *)CFWriteStreamCopyError(writeStream);
			}
			else
			{
			// 获取成功写入的字节数
				bytesWritten = (size_t)result;
				
				// We always set waiting to true in this scenario.
				// CFStream may have altered our underlying socket to non-blocking.
				// Thus if we attempt to write without a callback, we may end up blocking our queue.
				waiting = YES;
			}
			
			#endif
		}
		else
		{
		// 如果没使用CF流
			// We're going to use the SSLWrite function.
			// 
			// OSStatus SSLWrite(SSLContextRef context, const void *data, size_t dataLength, size_t *processed)
			// 
			// Parameters:
			// context     - An SSL session context reference.
			// data        - A pointer to the buffer of data to write.
			// dataLength  - The amount, in bytes, of data to write.
			// processed   - On return, the length, in bytes, of the data actually written.
			// 
			// It sounds pretty straight-forward,
			// but there are a few caveats you should be aware of.
			// 
			// The SSLWrite method operates in a non-obvious (and rather annoying) manner.
			// According to the documentation:
			// 
			//   Because you may configure the underlying connection to operate in a non-blocking manner,
			//   a write operation might return errSSLWouldBlock, indicating that less data than requested
			//   was actually transferred. In this case, you should repeat the call to SSLWrite until some
			//   other result is returned.
			// 
			// This sounds perfect, but when our SSLWriteFunction returns errSSLWouldBlock,
			// then the SSLWrite method returns (with the proper errSSLWouldBlock return value),
			// but it sets processed to dataLength !!
			// 
			// In other words, if the SSLWrite function doesn't completely write all the data we tell it to,
			// then it doesn't tell us how many bytes were actually written. So, for example, if we tell it to
			// write 256 bytes then it might actually write 128 bytes, but then report 0 bytes written.
			// 
			// You might be wondering:
			// If the SSLWrite function doesn't tell us how many bytes were written,
			// then how in the world are we supposed to update our parameters (buffer & bytesToWrite)
			// for the next time we invoke SSLWrite?
			// 
			// The answer is that SSLWrite cached all the data we told it to write,
			// and it will push out that data next time we call SSLWrite.
			// If we call SSLWrite with new data, it will push out the cached data first, and then the new data.
			// If we call SSLWrite with empty data, then it will simply push out the cached data.
			// 
			// For this purpose we're going to break large writes into a series of smaller writes.
			// This allows us to report progress back to the delegate.
			
			OSStatus result;
			
			BOOL hasCachedDataToWrite = (sslWriteCachedLength > 0);
			BOOL hasNewDataToWrite = YES;
			
			if (hasCachedDataToWrite)
			{
			// 如果有缓存的数据
				size_t processed = 0;
				调用一次SSLWrite
				result = SSLWrite(sslContext, NULL, 0, &processed);
				
				if (result == noErr)
				{
				// 如果没报错，那么写的数据
					bytesWritten = sslWriteCachedLength;
					sslWriteCachedLength = 0;
					
					if ([currentWrite->buffer length] == (currentWrite->bytesDone + bytesWritten))
					{
						// We've written all data for the current write.
						hasNewDataToWrite = NO;
					}
				}
				else
				{
					if (result == errSSLWouldBlock)
					{
						waiting = YES;
					}
					else
					{
						error = [self sslError:result];
					}
					
					// Can't write any new data since we were unable to write the cached data.
					hasNewDataToWrite = NO;
				}
			}
			
			if (hasNewDataToWrite)
			{
				const uint8_t *buffer = (const uint8_t *)[currentWrite->buffer bytes]
				                                        + currentWrite->bytesDone
				                                        + bytesWritten;
				
				NSUInteger bytesToWrite = [currentWrite->buffer length] - currentWrite->bytesDone - bytesWritten;
				
				if (bytesToWrite > SIZE_MAX) // NSUInteger may be bigger than size_t (write param 3)
				{
					bytesToWrite = SIZE_MAX;
				}
				
				size_t bytesRemaining = bytesToWrite;
				
				BOOL keepLooping = YES;
				while (keepLooping)
				{
					const size_t sslMaxBytesToWrite = 32768;
					size_t sslBytesToWrite = MIN(bytesRemaining, sslMaxBytesToWrite);
					size_t sslBytesWritten = 0;
					
					result = SSLWrite(sslContext, buffer, sslBytesToWrite, &sslBytesWritten);
					
					if (result == noErr)
					{
						buffer += sslBytesWritten;
						bytesWritten += sslBytesWritten;
						bytesRemaining -= sslBytesWritten;
						
						keepLooping = (bytesRemaining > 0);
					}
					else
					{
						if (result == errSSLWouldBlock)
						{
							waiting = YES;
							sslWriteCachedLength = sslBytesToWrite;
						}
						else
						{
							error = [self sslError:result];
						}
						
						keepLooping = NO;
					}
					
				} // while (keepLooping)
				
			} // if (hasNewDataToWrite)
		}
	}
	else
	{
		// 
		// Writing data directly over raw socket
		// 
		
		int socketFD = (socket4FD != SOCKET_NULL) ? socket4FD : (socket6FD != SOCKET_NULL) ? socket6FD : socketUN;
		
		const uint8_t *buffer = (const uint8_t *)[currentWrite->buffer bytes] + currentWrite->bytesDone;
		
		NSUInteger bytesToWrite = [currentWrite->buffer length] - currentWrite->bytesDone;
		
		if (bytesToWrite > SIZE_MAX) // NSUInteger may be bigger than size_t (write param 3)
		{
			bytesToWrite = SIZE_MAX;
		}
		
		ssize_t result = write(socketFD, buffer, (size_t)bytesToWrite);
		LogVerbose(@"wrote to socket = %zd", result);
		
		// Check results
		if (result < 0)
		{
			if (errno == EWOULDBLOCK)
			{
				waiting = YES;
			}
			else
			{
				error = [self errorWithErrno:errno reason:@"Error in write() function"];
			}
		}
		else
		{
			bytesWritten = result;
		}
	}
	
	// We're done with our writing.
	// If we explictly ran into a situation where the socket told us there was no room in the buffer,
	// then we immediately resume listening for notifications.
	// 
	// We must do this before we dequeue another write,
	// as that may in turn invoke this method again.
	// 
	// Note that if CFStream is involved, it may have maliciously put our socket in blocking mode.
	
	if (waiting)
	{
		flags &= ~kSocketCanAcceptBytes;
		
		if (![self usingCFStreamForTLS])
		{
			[self resumeWriteSource];
		}
	}
	
	// Check our results
	
	BOOL done = NO;
	
	if (bytesWritten > 0)
	{
		// Update total amount read for the current write
		currentWrite->bytesDone += bytesWritten;
		LogVerbose(@"currentWrite->bytesDone = %lu", (unsigned long)currentWrite->bytesDone);
		
		// Is packet done?
		done = (currentWrite->bytesDone == [currentWrite->buffer length]);
	}
	
	if (done)
	{
		[self completeCurrentWrite];
		
		if (!error)
		{
			dispatch_async(socketQueue, ^{ @autoreleasepool{
				
				[self maybeDequeueWrite];
			}});
		}
	}
	else
	{
		// We were unable to finish writing the data,
		// so we're waiting for another callback to notify us of available space in the lower-level output buffer.
		
		if (!waiting && !error)
		{
			// This would be the case if our write was able to accept some data, but not all of it.
			
			flags &= ~kSocketCanAcceptBytes;
			
			if (![self usingCFStreamForTLS])
			{
				[self resumeWriteSource];
			}
		}
		
		if (bytesWritten > 0)
		{
			// We're not done with the entire write, but we have written some bytes
			
			__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;

			if (delegateQueue && [theDelegate respondsToSelector:@selector(socket:didWritePartialDataOfLength:tag:)])
			{
				long theWriteTag = currentWrite->tag;
				
				dispatch_async(delegateQueue, ^{ @autoreleasepool {
					
					[theDelegate socket:self didWritePartialDataOfLength:bytesWritten tag:theWriteTag];
				}});
			}
		}
	}
	
	// Check for errors
	
	if (error)
	{
		[self closeWithError:[self errorWithErrno:errno reason:@"Error in write() function"]];
	}
	
	// Do not add any code here without first adding a return statement in the error case above.
}

- (void)completeCurrentWrite
{
	LogTrace();
	
	NSAssert(currentWrite, @"Trying to complete current write when there is no current write.");
	

	__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;
	
	if (delegateQueue && [theDelegate respondsToSelector:@selector(socket:didWriteDataWithTag:)])
	{
		long theWriteTag = currentWrite->tag;
		
		dispatch_async(delegateQueue, ^{ @autoreleasepool {
			
			[theDelegate socket:self didWriteDataWithTag:theWriteTag];
		}});
	}
	
	[self endCurrentWrite];
}

- (void)endCurrentWrite
{
	if (writeTimer)
	{
		dispatch_source_cancel(writeTimer);
		writeTimer = NULL;
	}
	
	currentWrite = nil;
}

- (void)setupWriteTimerWithTimeout:(NSTimeInterval)timeout
{
	if (timeout >= 0.0)
	{
		writeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, socketQueue);
		
		__weak GCDAsyncSocket *weakSelf = self;
		
		dispatch_source_set_event_handler(writeTimer, ^{ @autoreleasepool {
		#pragma clang diagnostic push
		#pragma clang diagnostic warning "-Wimplicit-retain-self"
			
			__strong GCDAsyncSocket *strongSelf = weakSelf;
			if (strongSelf == nil) return_from_block;
			
			[strongSelf doWriteTimeout];
			
		#pragma clang diagnostic pop
		}});
		
		#if !OS_OBJECT_USE_OBJC
		dispatch_source_t theWriteTimer = writeTimer;
		dispatch_source_set_cancel_handler(writeTimer, ^{
		#pragma clang diagnostic push
		#pragma clang diagnostic warning "-Wimplicit-retain-self"
			
			LogVerbose(@"dispatch_release(writeTimer)");
			dispatch_release(theWriteTimer);
			
		#pragma clang diagnostic pop
		});
		#endif
		
		dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
		
		dispatch_source_set_timer(writeTimer, tt, DISPATCH_TIME_FOREVER, 0);
		dispatch_resume(writeTimer);
	}
}

- (void)doWriteTimeout
{
	// This is a little bit tricky.
	// Ideally we'd like to synchronously query the delegate about a timeout extension.
	// But if we do so synchronously we risk a possible deadlock.
	// So instead we have to do so asynchronously, and callback to ourselves from within the delegate block.
	
	flags |= kWritesPaused;
	
	__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;

	if (delegateQueue && [theDelegate respondsToSelector:@selector(socket:shouldTimeoutWriteWithTag:elapsed:bytesDone:)])
	{
		GCDAsyncWritePacket *theWrite = currentWrite;
		
		dispatch_async(delegateQueue, ^{ @autoreleasepool {
			
			NSTimeInterval timeoutExtension = 0.0;
			
			timeoutExtension = [theDelegate socket:self shouldTimeoutWriteWithTag:theWrite->tag
			                                                              elapsed:theWrite->timeout
			                                                            bytesDone:theWrite->bytesDone];
			
            dispatch_async(self->socketQueue, ^{ @autoreleasepool {
				
				[self doWriteTimeoutWithExtension:timeoutExtension];
			}});
		}});
	}
	else
	{
		[self doWriteTimeoutWithExtension:0.0];
	}
}

- (void)doWriteTimeoutWithExtension:(NSTimeInterval)timeoutExtension
{
	if (currentWrite)
	{
		if (timeoutExtension > 0.0)
		{
			currentWrite->timeout += timeoutExtension;
			
			// Reschedule the timer
			dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutExtension * NSEC_PER_SEC));
			dispatch_source_set_timer(writeTimer, tt, DISPATCH_TIME_FOREVER, 0);
			
			// Unpause writes, and continue
			flags &= ~kWritesPaused;
			[self doWriteData];
		}
		else
		{
			LogVerbose(@"WriteTimeout");
			
			[self closeWithError:[self writeTimeoutError]];
		}
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Security
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)startTLS:(NSDictionary *)tlsSettings
{
	LogTrace();
	
	if (tlsSettings == nil)
    {
        // Passing nil/NULL to CFReadStreamSetProperty will appear to work the same as passing an empty dictionary,
        // but causes problems if we later try to fetch the remote host's certificate.
        // 
        // To be exact, it causes the following to return NULL instead of the normal result:
        // CFReadStreamCopyProperty(readStream, kCFStreamPropertySSLPeerCertificates)
        // 
        // So we use an empty dictionary instead, which works perfectly.
        
        tlsSettings = [NSDictionary dictionary];
    }
	
	GCDAsyncSpecialPacket *packet = [[GCDAsyncSpecialPacket alloc] initWithTLSSettings:tlsSettings];
	
	dispatch_async(socketQueue, ^{ @autoreleasepool {
		
        if ((self->flags & kSocketStarted) && !(self->flags & kQueuedTLS) && !(self->flags & kForbidReadsWrites))
		{
            [self->readQueue addObject:packet];
            [self->writeQueue addObject:packet];
			
            self->flags |= kQueuedTLS;
			
			[self maybeDequeueRead];
			[self maybeDequeueWrite];
		}
	}});
	
}

- (void)maybeStartTLS
{
	// We can't start TLS until:
	// - All queued reads prior to the user calling startTLS are complete
	// - All queued writes prior to the user calling startTLS are complete
	// 
	// We'll know these conditions are met when both kStartingReadTLS and kStartingWriteTLS are set
	
	if ((flags & kStartingReadTLS) && (flags & kStartingWriteTLS))
	{
		BOOL useSecureTransport = YES;
		
		#if TARGET_OS_IPHONE
		{
			GCDAsyncSpecialPacket *tlsPacket = (GCDAsyncSpecialPacket *)currentRead;
            NSDictionary *tlsSettings = @{};
            if (tlsPacket) {
                tlsSettings = tlsPacket->tlsSettings;
            }
			NSNumber *value = [tlsSettings objectForKey:GCDAsyncSocketUseCFStreamForTLS];
			if (value && [value boolValue])
				useSecureTransport = NO;
		}
		#endif
		
		if (useSecureTransport)
		{
			[self ssl_startTLS];
		}
		else
		{
		#if TARGET_OS_IPHONE
			[self cf_startTLS];
		#endif
		}
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Security via SecureTransport
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (OSStatus)sslReadWithBuffer:(void *)buffer length:(size_t *)bufferLength
{
	LogVerbose(@"sslReadWithBuffer:%p length:%lu", buffer, (unsigned long)*bufferLength);
	
	if ((socketFDBytesAvailable == 0) && ([sslPreBuffer availableBytes] == 0))
	{
		LogVerbose(@"%@ - No data available to read...", THIS_METHOD);
		
		// No data available to read.
		// 
		// Need to wait for readSource to fire and notify us of
		// available data in the socket's internal read buffer.
		
		[self resumeReadSource];
		
		*bufferLength = 0;
		return errSSLWouldBlock;
	}
	
	size_t totalBytesRead = 0;
	size_t totalBytesLeftToBeRead = *bufferLength;
	
	BOOL done = NO;
	BOOL socketError = NO;
	
	// 
	// STEP 1 : READ FROM SSL PRE BUFFER
	// 
	
	size_t sslPreBufferLength = [sslPreBuffer availableBytes];
	
	if (sslPreBufferLength > 0)
	{
		LogVerbose(@"%@: Reading from SSL pre buffer...", THIS_METHOD);
		
		size_t bytesToCopy;
		if (sslPreBufferLength > totalBytesLeftToBeRead)
			bytesToCopy = totalBytesLeftToBeRead;
		else
			bytesToCopy = sslPreBufferLength;
		
		LogVerbose(@"%@: Copying %zu bytes from sslPreBuffer", THIS_METHOD, bytesToCopy);
		
		memcpy(buffer, [sslPreBuffer readBuffer], bytesToCopy);
		[sslPreBuffer didRead:bytesToCopy];
		
		LogVerbose(@"%@: sslPreBuffer.length = %zu", THIS_METHOD, [sslPreBuffer availableBytes]);
		
		totalBytesRead += bytesToCopy;
		totalBytesLeftToBeRead -= bytesToCopy;
		
		done = (totalBytesLeftToBeRead == 0);
		
		if (done) LogVerbose(@"%@: Complete", THIS_METHOD);
	}
	
	// 
	// STEP 2 : READ FROM SOCKET
	// 
	
	if (!done && (socketFDBytesAvailable > 0))
	{
		LogVerbose(@"%@: Reading from socket...", THIS_METHOD);
		
		int socketFD = (socket4FD != SOCKET_NULL) ? socket4FD : (socket6FD != SOCKET_NULL) ? socket6FD : socketUN;
		
		BOOL readIntoPreBuffer;
		size_t bytesToRead;
		uint8_t *buf;
		
		if (socketFDBytesAvailable > totalBytesLeftToBeRead)
		{
			// Read all available data from socket into sslPreBuffer.
			// Then copy requested amount into dataBuffer.
			
			LogVerbose(@"%@: Reading into sslPreBuffer...", THIS_METHOD);
			
			[sslPreBuffer ensureCapacityForWrite:socketFDBytesAvailable];
			
			readIntoPreBuffer = YES;
			bytesToRead = (size_t)socketFDBytesAvailable;
			buf = [sslPreBuffer writeBuffer];
		}
		else
		{
			// Read available data from socket directly into dataBuffer.
			
			LogVerbose(@"%@: Reading directly into dataBuffer...", THIS_METHOD);
			
			readIntoPreBuffer = NO;
			bytesToRead = totalBytesLeftToBeRead;
			buf = (uint8_t *)buffer + totalBytesRead;
		}
		
		ssize_t result = read(socketFD, buf, bytesToRead);
		LogVerbose(@"%@: read from socket = %zd", THIS_METHOD, result);
		
		if (result < 0)
		{
			LogVerbose(@"%@: read errno = %i", THIS_METHOD, errno);
			
			if (errno != EWOULDBLOCK)
			{
				socketError = YES;
			}
			
			socketFDBytesAvailable = 0;
		}
		else if (result == 0)
		{
			LogVerbose(@"%@: read EOF", THIS_METHOD);
			
			socketError = YES;
			socketFDBytesAvailable = 0;
		}
		else
		{
			size_t bytesReadFromSocket = result;
			
			if (socketFDBytesAvailable > bytesReadFromSocket)
				socketFDBytesAvailable -= bytesReadFromSocket;
			else
				socketFDBytesAvailable = 0;
			
			if (readIntoPreBuffer)
			{
				[sslPreBuffer didWrite:bytesReadFromSocket];
				
				size_t bytesToCopy = MIN(totalBytesLeftToBeRead, bytesReadFromSocket);
				
				LogVerbose(@"%@: Copying %zu bytes out of sslPreBuffer", THIS_METHOD, bytesToCopy);
				
				memcpy((uint8_t *)buffer + totalBytesRead, [sslPreBuffer readBuffer], bytesToCopy);
				[sslPreBuffer didRead:bytesToCopy];
				
				totalBytesRead += bytesToCopy;
				totalBytesLeftToBeRead -= bytesToCopy;
				
				LogVerbose(@"%@: sslPreBuffer.length = %zu", THIS_METHOD, [sslPreBuffer availableBytes]);
			}
			else
			{
				totalBytesRead += bytesReadFromSocket;
				totalBytesLeftToBeRead -= bytesReadFromSocket;
			}
			
			done = (totalBytesLeftToBeRead == 0);
			
			if (done) LogVerbose(@"%@: Complete", THIS_METHOD);
		}
	}
	
	*bufferLength = totalBytesRead;
	
	if (done)
		return noErr;
	
	if (socketError)
		return errSSLClosedAbort;
	
	return errSSLWouldBlock;
}

- (OSStatus)sslWriteWithBuffer:(const void *)buffer length:(size_t *)bufferLength
{
	if (!(flags & kSocketCanAcceptBytes))
	{
		// Unable to write.
		// 
		// Need to wait for writeSource to fire and notify us of
		// available space in the socket's internal write buffer.
		
		[self resumeWriteSource];
		
		*bufferLength = 0;
		return errSSLWouldBlock;
	}
	
	size_t bytesToWrite = *bufferLength;
	size_t bytesWritten = 0;
	
	BOOL done = NO;
	BOOL socketError = NO;
	
	int socketFD = (socket4FD != SOCKET_NULL) ? socket4FD : (socket6FD != SOCKET_NULL) ? socket6FD : socketUN;
	
	ssize_t result = write(socketFD, buffer, bytesToWrite);
	
	if (result < 0)
	{
		if (errno != EWOULDBLOCK)
		{
			socketError = YES;
		}
		
		flags &= ~kSocketCanAcceptBytes;
	}
	else if (result == 0)
	{
		flags &= ~kSocketCanAcceptBytes;
	}
	else
	{
		bytesWritten = result;
		
		done = (bytesWritten == bytesToWrite);
	}
	
	*bufferLength = bytesWritten;
	
	if (done)
		return noErr;
	
	if (socketError)
		return errSSLClosedAbort;
	
	return errSSLWouldBlock;
}

static OSStatus SSLReadFunction(SSLConnectionRef connection, void *data, size_t *dataLength)
{
	GCDAsyncSocket *asyncSocket = (__bridge GCDAsyncSocket *)connection;
	
	NSCAssert(dispatch_get_specific(asyncSocket->IsOnSocketQueueOrTargetQueueKey), @"What the deuce?");
	
	return [asyncSocket sslReadWithBuffer:data length:dataLength];
}

static OSStatus SSLWriteFunction(SSLConnectionRef connection, const void *data, size_t *dataLength)
{
	GCDAsyncSocket *asyncSocket = (__bridge GCDAsyncSocket *)connection;
	
	NSCAssert(dispatch_get_specific(asyncSocket->IsOnSocketQueueOrTargetQueueKey), @"What the deuce?");
	
	return [asyncSocket sslWriteWithBuffer:data length:dataLength];
}

- (void)ssl_startTLS
{
	LogTrace();
	
	LogVerbose(@"Starting TLS (via SecureTransport)...");
	
	OSStatus status;
	
	GCDAsyncSpecialPacket *tlsPacket = (GCDAsyncSpecialPacket *)currentRead;
	if (tlsPacket == nil) // Code to quiet the analyzer
	{
		NSAssert(NO, @"Logic error");
		
		[self closeWithError:[self otherError:@"Logic error"]];
		return;
	}
	NSDictionary *tlsSettings = tlsPacket->tlsSettings;
	
	// Create SSLContext, and setup IO callbacks and connection ref
	
	NSNumber *isServerNumber = [tlsSettings objectForKey:(__bridge NSString *)kCFStreamSSLIsServer];
	BOOL isServer = [isServerNumber boolValue];
	
	#if TARGET_OS_IPHONE || (__MAC_OS_X_VERSION_MIN_REQUIRED >= 1080)
	{
		if (isServer)
			sslContext = SSLCreateContext(kCFAllocatorDefault, kSSLServerSide, kSSLStreamType);
		else
			sslContext = SSLCreateContext(kCFAllocatorDefault, kSSLClientSide, kSSLStreamType);
		
		if (sslContext == NULL)
		{
			[self closeWithError:[self otherError:@"Error in SSLCreateContext"]];
			return;
		}
	}
	#else // (__MAC_OS_X_VERSION_MIN_REQUIRED < 1080)
	{
		status = SSLNewContext(isServer, &sslContext);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLNewContext"]];
			return;
		}
	}
	#endif
	
	status = SSLSetIOFuncs(sslContext, &SSLReadFunction, &SSLWriteFunction);
	if (status != noErr)
	{
		[self closeWithError:[self otherError:@"Error in SSLSetIOFuncs"]];
		return;
	}
	
	status = SSLSetConnection(sslContext, (__bridge SSLConnectionRef)self);
	if (status != noErr)
	{
		[self closeWithError:[self otherError:@"Error in SSLSetConnection"]];
		return;
	}


	NSNumber *shouldManuallyEvaluateTrust = [tlsSettings objectForKey:GCDAsyncSocketManuallyEvaluateTrust];
	if ([shouldManuallyEvaluateTrust boolValue])
	{
		if (isServer)
		{
			[self closeWithError:[self otherError:@"Manual trust validation is not supported for server sockets"]];
			return;
		}
		
		status = SSLSetSessionOption(sslContext, kSSLSessionOptionBreakOnServerAuth, true);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetSessionOption"]];
			return;
		}
		
		#if !TARGET_OS_IPHONE && (__MAC_OS_X_VERSION_MIN_REQUIRED < 1080)
		
		// Note from Apple's documentation:
		//
		// It is only necessary to call SSLSetEnableCertVerify on the Mac prior to OS X 10.8.
		// On OS X 10.8 and later setting kSSLSessionOptionBreakOnServerAuth always disables the
		// built-in trust evaluation. All versions of iOS behave like OS X 10.8 and thus
		// SSLSetEnableCertVerify is not available on that platform at all.
		
		status = SSLSetEnableCertVerify(sslContext, NO);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetEnableCertVerify"]];
			return;
		}
		
		#endif
	}

	// Configure SSLContext from given settings
	// 
	// Checklist:
	//  1. kCFStreamSSLPeerName
	//  2. kCFStreamSSLCertificates
	//  3. GCDAsyncSocketSSLPeerID
	//  4. GCDAsyncSocketSSLProtocolVersionMin
	//  5. GCDAsyncSocketSSLProtocolVersionMax
	//  6. GCDAsyncSocketSSLSessionOptionFalseStart
	//  7. GCDAsyncSocketSSLSessionOptionSendOneByteRecord
	//  8. GCDAsyncSocketSSLCipherSuites
	//  9. GCDAsyncSocketSSLDiffieHellmanParameters (Mac)
    // 10. GCDAsyncSocketSSLALPN
	//
	// Deprecated (throw error):
	// 10. kCFStreamSSLAllowsAnyRoot
	// 11. kCFStreamSSLAllowsExpiredRoots
	// 12. kCFStreamSSLAllowsExpiredCertificates
	// 13. kCFStreamSSLValidatesCertificateChain
	// 14. kCFStreamSSLLevel
	
	NSObject *value;
	
	// 1. kCFStreamSSLPeerName
	
	value = [tlsSettings objectForKey:(__bridge NSString *)kCFStreamSSLPeerName];
	if ([value isKindOfClass:[NSString class]])
	{
		NSString *peerName = (NSString *)value;
		
		const char *peer = [peerName UTF8String];
		size_t peerLen = strlen(peer);
		
		status = SSLSetPeerDomainName(sslContext, peer, peerLen);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetPeerDomainName"]];
			return;
		}
	}
	else if (value)
	{
		NSAssert(NO, @"Invalid value for kCFStreamSSLPeerName. Value must be of type NSString.");
		
		[self closeWithError:[self otherError:@"Invalid value for kCFStreamSSLPeerName."]];
		return;
	}
	
	// 2. kCFStreamSSLCertificates
	
	value = [tlsSettings objectForKey:(__bridge NSString *)kCFStreamSSLCertificates];
	if ([value isKindOfClass:[NSArray class]])
	{
		NSArray *certs = (NSArray *)value;
		
		status = SSLSetCertificate(sslContext, (__bridge CFArrayRef)certs);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetCertificate"]];
			return;
		}
	}
	else if (value)
	{
		NSAssert(NO, @"Invalid value for kCFStreamSSLCertificates. Value must be of type NSArray.");
		
		[self closeWithError:[self otherError:@"Invalid value for kCFStreamSSLCertificates."]];
		return;
	}
	
	// 3. GCDAsyncSocketSSLPeerID
	
	value = [tlsSettings objectForKey:GCDAsyncSocketSSLPeerID];
	if ([value isKindOfClass:[NSData class]])
	{
		NSData *peerIdData = (NSData *)value;
		
		status = SSLSetPeerID(sslContext, [peerIdData bytes], [peerIdData length]);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetPeerID"]];
			return;
		}
	}
	else if (value)
	{
		NSAssert(NO, @"Invalid value for GCDAsyncSocketSSLPeerID. Value must be of type NSData."
		             @" (You can convert strings to data using a method like"
		             @" [string dataUsingEncoding:NSUTF8StringEncoding])");
		
		[self closeWithError:[self otherError:@"Invalid value for GCDAsyncSocketSSLPeerID."]];
		return;
	}
	
	// 4. GCDAsyncSocketSSLProtocolVersionMin
	
	value = [tlsSettings objectForKey:GCDAsyncSocketSSLProtocolVersionMin];
	if ([value isKindOfClass:[NSNumber class]])
	{
		SSLProtocol minProtocol = (SSLProtocol)[(NSNumber *)value intValue];
		if (minProtocol != kSSLProtocolUnknown)
		{
			status = SSLSetProtocolVersionMin(sslContext, minProtocol);
			if (status != noErr)
			{
				[self closeWithError:[self otherError:@"Error in SSLSetProtocolVersionMin"]];
				return;
			}
		}
	}
	else if (value)
	{
		NSAssert(NO, @"Invalid value for GCDAsyncSocketSSLProtocolVersionMin. Value must be of type NSNumber.");
		
		[self closeWithError:[self otherError:@"Invalid value for GCDAsyncSocketSSLProtocolVersionMin."]];
		return;
	}
	
	// 5. GCDAsyncSocketSSLProtocolVersionMax
	
	value = [tlsSettings objectForKey:GCDAsyncSocketSSLProtocolVersionMax];
	if ([value isKindOfClass:[NSNumber class]])
	{
		SSLProtocol maxProtocol = (SSLProtocol)[(NSNumber *)value intValue];
		if (maxProtocol != kSSLProtocolUnknown)
		{
			status = SSLSetProtocolVersionMax(sslContext, maxProtocol);
			if (status != noErr)
			{
				[self closeWithError:[self otherError:@"Error in SSLSetProtocolVersionMax"]];
				return;
			}
		}
	}
	else if (value)
	{
		NSAssert(NO, @"Invalid value for GCDAsyncSocketSSLProtocolVersionMax. Value must be of type NSNumber.");
		
		[self closeWithError:[self otherError:@"Invalid value for GCDAsyncSocketSSLProtocolVersionMax."]];
		return;
	}
	
	// 6. GCDAsyncSocketSSLSessionOptionFalseStart
	
	value = [tlsSettings objectForKey:GCDAsyncSocketSSLSessionOptionFalseStart];
	if ([value isKindOfClass:[NSNumber class]])
	{
		NSNumber *falseStart = (NSNumber *)value;
		status = SSLSetSessionOption(sslContext, kSSLSessionOptionFalseStart, [falseStart boolValue]);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetSessionOption (kSSLSessionOptionFalseStart)"]];
			return;
		}
	}
	else if (value)
	{
		NSAssert(NO, @"Invalid value for GCDAsyncSocketSSLSessionOptionFalseStart. Value must be of type NSNumber.");
		
		[self closeWithError:[self otherError:@"Invalid value for GCDAsyncSocketSSLSessionOptionFalseStart."]];
		return;
	}
	
	// 7. GCDAsyncSocketSSLSessionOptionSendOneByteRecord
	
	value = [tlsSettings objectForKey:GCDAsyncSocketSSLSessionOptionSendOneByteRecord];
	if ([value isKindOfClass:[NSNumber class]])
	{
		NSNumber *oneByteRecord = (NSNumber *)value;
		status = SSLSetSessionOption(sslContext, kSSLSessionOptionSendOneByteRecord, [oneByteRecord boolValue]);
		if (status != noErr)
		{
			[self closeWithError:
			  [self otherError:@"Error in SSLSetSessionOption (kSSLSessionOptionSendOneByteRecord)"]];
			return;
		}
	}
	else if (value)
	{
		NSAssert(NO, @"Invalid value for GCDAsyncSocketSSLSessionOptionSendOneByteRecord."
		             @" Value must be of type NSNumber.");
		
		[self closeWithError:[self otherError:@"Invalid value for GCDAsyncSocketSSLSessionOptionSendOneByteRecord."]];
		return;
	}
	
	// 8. GCDAsyncSocketSSLCipherSuites
	
	value = [tlsSettings objectForKey:GCDAsyncSocketSSLCipherSuites];
	if ([value isKindOfClass:[NSArray class]])
	{
		NSArray *cipherSuites = (NSArray *)value;
		NSUInteger numberCiphers = [cipherSuites count];
		SSLCipherSuite ciphers[numberCiphers];
		
		NSUInteger cipherIndex;
		for (cipherIndex = 0; cipherIndex < numberCiphers; cipherIndex++)
		{
			NSNumber *cipherObject = [cipherSuites objectAtIndex:cipherIndex];
			ciphers[cipherIndex] = (SSLCipherSuite)[cipherObject unsignedIntValue];
		}
		
		status = SSLSetEnabledCiphers(sslContext, ciphers, numberCiphers);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetEnabledCiphers"]];
			return;
		}
	}
	else if (value)
	{
		NSAssert(NO, @"Invalid value for GCDAsyncSocketSSLCipherSuites. Value must be of type NSArray.");
		
		[self closeWithError:[self otherError:@"Invalid value for GCDAsyncSocketSSLCipherSuites."]];
		return;
	}
	
	// 9. GCDAsyncSocketSSLDiffieHellmanParameters
	
	#if !TARGET_OS_IPHONE
	value = [tlsSettings objectForKey:GCDAsyncSocketSSLDiffieHellmanParameters];
	if ([value isKindOfClass:[NSData class]])
	{
		NSData *diffieHellmanData = (NSData *)value;
		
		status = SSLSetDiffieHellmanParams(sslContext, [diffieHellmanData bytes], [diffieHellmanData length]);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetDiffieHellmanParams"]];
			return;
		}
	}
	else if (value)
	{
		NSAssert(NO, @"Invalid value for GCDAsyncSocketSSLDiffieHellmanParameters. Value must be of type NSData.");
		
		[self closeWithError:[self otherError:@"Invalid value for GCDAsyncSocketSSLDiffieHellmanParameters."]];
		return;
	}
	#endif

    // 10. kCFStreamSSLCertificates
    value = [tlsSettings objectForKey:GCDAsyncSocketSSLALPN];
    if ([value isKindOfClass:[NSArray class]])
    {
        if (@available(iOS 11.0, macOS 10.13, tvOS 11.0, *))
        {
            CFArrayRef protocols = (__bridge CFArrayRef)((NSArray *) value);
            status = SSLSetALPNProtocols(sslContext, protocols);
            if (status != noErr)
            {
                [self closeWithError:[self otherError:@"Error in SSLSetALPNProtocols"]];
                return;
            }
        }
        else
        {
            NSAssert(NO, @"Security option unavailable - GCDAsyncSocketSSLALPN"
                     @" - iOS 11.0, macOS 10.13 required");
            [self closeWithError:[self otherError:@"Security option unavailable - GCDAsyncSocketSSLALPN"]];
        }
    }
    else if (value)
    {
        NSAssert(NO, @"Invalid value for GCDAsyncSocketSSLALPN. Value must be of type NSArray.");
        
        [self closeWithError:[self otherError:@"Invalid value for GCDAsyncSocketSSLALPN."]];
        return;
    }
    
	// DEPRECATED checks
	
	// 10. kCFStreamSSLAllowsAnyRoot
	
	#pragma clang diagnostic push
	#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	value = [tlsSettings objectForKey:(__bridge NSString *)kCFStreamSSLAllowsAnyRoot];
	#pragma clang diagnostic pop
	if (value)
	{
		NSAssert(NO, @"Security option unavailable - kCFStreamSSLAllowsAnyRoot"
		             @" - You must use manual trust evaluation");
		
		[self closeWithError:[self otherError:@"Security option unavailable - kCFStreamSSLAllowsAnyRoot"]];
		return;
	}
	
	// 11. kCFStreamSSLAllowsExpiredRoots
	
	#pragma clang diagnostic push
	#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	value = [tlsSettings objectForKey:(__bridge NSString *)kCFStreamSSLAllowsExpiredRoots];
	#pragma clang diagnostic pop
	if (value)
	{
		NSAssert(NO, @"Security option unavailable - kCFStreamSSLAllowsExpiredRoots"
		             @" - You must use manual trust evaluation");
		
		[self closeWithError:[self otherError:@"Security option unavailable - kCFStreamSSLAllowsExpiredRoots"]];
		return;
	}
	
	// 12. kCFStreamSSLValidatesCertificateChain
	
	#pragma clang diagnostic push
	#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	value = [tlsSettings objectForKey:(__bridge NSString *)kCFStreamSSLValidatesCertificateChain];
	#pragma clang diagnostic pop
	if (value)
	{
		NSAssert(NO, @"Security option unavailable - kCFStreamSSLValidatesCertificateChain"
		             @" - You must use manual trust evaluation");
		
		[self closeWithError:[self otherError:@"Security option unavailable - kCFStreamSSLValidatesCertificateChain"]];
		return;
	}
	
	// 13. kCFStreamSSLAllowsExpiredCertificates
	
	#pragma clang diagnostic push
	#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	value = [tlsSettings objectForKey:(__bridge NSString *)kCFStreamSSLAllowsExpiredCertificates];
	#pragma clang diagnostic pop
	if (value)
	{
		NSAssert(NO, @"Security option unavailable - kCFStreamSSLAllowsExpiredCertificates"
		             @" - You must use manual trust evaluation");
		
		[self closeWithError:[self otherError:@"Security option unavailable - kCFStreamSSLAllowsExpiredCertificates"]];
		return;
	}
	
	// 14. kCFStreamSSLLevel
	
	#pragma clang diagnostic push
	#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	value = [tlsSettings objectForKey:(__bridge NSString *)kCFStreamSSLLevel];
	#pragma clang diagnostic pop
	if (value)
	{
		NSAssert(NO, @"Security option unavailable - kCFStreamSSLLevel"
		             @" - You must use GCDAsyncSocketSSLProtocolVersionMin & GCDAsyncSocketSSLProtocolVersionMax");
		
		[self closeWithError:[self otherError:@"Security option unavailable - kCFStreamSSLLevel"]];
		return;
	}
	
	// Setup the sslPreBuffer
	// 
	// Any data in the preBuffer needs to be moved into the sslPreBuffer,
	// as this data is now part of the secure read stream.
	
	sslPreBuffer = [[GCDAsyncSocketPreBuffer alloc] initWithCapacity:(1024 * 4)];
	
	size_t preBufferLength  = [preBuffer availableBytes];
	
	if (preBufferLength > 0)
	{
		[sslPreBuffer ensureCapacityForWrite:preBufferLength];
		
		memcpy([sslPreBuffer writeBuffer], [preBuffer readBuffer], preBufferLength);
		[preBuffer didRead:preBufferLength];
		[sslPreBuffer didWrite:preBufferLength];
	}
	
	sslErrCode = lastSSLHandshakeError = noErr;
	
	// Start the SSL Handshake process
	
	[self ssl_continueSSLHandshake];
}

- (void)ssl_continueSSLHandshake
{
	LogTrace();
	
	// If the return value is noErr, the session is ready for normal secure communication.
	// If the return value is errSSLWouldBlock, the SSLHandshake function must be called again.
	// If the return value is errSSLServerAuthCompleted, we ask delegate if we should trust the
	// server and then call SSLHandshake again to resume the handshake or close the connection
	// errSSLPeerBadCert SSL error.
	// Otherwise, the return value indicates an error code.
	
	OSStatus status = SSLHandshake(sslContext);
	lastSSLHandshakeError = status;
	
	if (status == noErr)
	{
		LogVerbose(@"SSLHandshake complete");
		
		flags &= ~kStartingReadTLS;
		flags &= ~kStartingWriteTLS;
		
		flags |=  kSocketSecure;
		
		__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;

		if (delegateQueue && [theDelegate respondsToSelector:@selector(socketDidSecure:)])
		{
			dispatch_async(delegateQueue, ^{ @autoreleasepool {
				
				[theDelegate socketDidSecure:self];
			}});
		}
		
		[self endCurrentRead];
		[self endCurrentWrite];
		
		[self maybeDequeueRead];
		[self maybeDequeueWrite];
	}
	else if (status == errSSLPeerAuthCompleted)
	{
		LogVerbose(@"SSLHandshake peerAuthCompleted - awaiting delegate approval");
		
		__block SecTrustRef trust = NULL;
		status = SSLCopyPeerTrust(sslContext, &trust);
		if (status != noErr)
		{
			[self closeWithError:[self sslError:status]];
			return;
		}
		
		int aStateIndex = stateIndex;
		dispatch_queue_t theSocketQueue = socketQueue;
		
		__weak GCDAsyncSocket *weakSelf = self;
		
		void (^comletionHandler)(BOOL) = ^(BOOL shouldTrust){ @autoreleasepool {
		#pragma clang diagnostic push
		#pragma clang diagnostic warning "-Wimplicit-retain-self"
			
			dispatch_async(theSocketQueue, ^{ @autoreleasepool {
				
				if (trust) {
					CFRelease(trust);
					trust = NULL;
				}
				
				__strong GCDAsyncSocket *strongSelf = weakSelf;
				if (strongSelf)
				{
					[strongSelf ssl_shouldTrustPeer:shouldTrust stateIndex:aStateIndex];
				}
			}});
			
		#pragma clang diagnostic pop
		}};
		
		__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;
		
		if (delegateQueue && [theDelegate respondsToSelector:@selector(socket:didReceiveTrust:completionHandler:)])
		{
			dispatch_async(delegateQueue, ^{ @autoreleasepool {
			
				[theDelegate socket:self didReceiveTrust:trust completionHandler:comletionHandler];
			}});
		}
		else
		{
			if (trust) {
				CFRelease(trust);
				trust = NULL;
			}
			
			NSString *msg = @"GCDAsyncSocketManuallyEvaluateTrust specified in tlsSettings,"
			                @" but delegate doesn't implement socket:shouldTrustPeer:";
			
			[self closeWithError:[self otherError:msg]];
			return;
		}
	}
	else if (status == errSSLWouldBlock)
	{
		LogVerbose(@"SSLHandshake continues...");
		
		// Handshake continues...
		// 
		// This method will be called again from doReadData or doWriteData.
	}
	else
	{
		[self closeWithError:[self sslError:status]];
	}
}

- (void)ssl_shouldTrustPeer:(BOOL)shouldTrust stateIndex:(int)aStateIndex
{
	LogTrace();
	
	if (aStateIndex != stateIndex)
	{
		LogInfo(@"Ignoring ssl_shouldTrustPeer - invalid state (maybe disconnected)");
		
		// One of the following is true
		// - the socket was disconnected
		// - the startTLS operation timed out
		// - the completionHandler was already invoked once
		
		return;
	}
	
	// Increment stateIndex to ensure completionHandler can only be called once.
	stateIndex++;
	
	if (shouldTrust)
	{
        NSAssert(lastSSLHandshakeError == errSSLPeerAuthCompleted, @"ssl_shouldTrustPeer called when last error is %d and not errSSLPeerAuthCompleted", (int)lastSSLHandshakeError);
		[self ssl_continueSSLHandshake];
	}
	else
	{
		[self closeWithError:[self sslError:errSSLPeerBadCert]];
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Security via CFStream
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

#if TARGET_OS_IPHONE

- (void)cf_finishSSLHandshake
{
	LogTrace();
	
	if ((flags & kStartingReadTLS) && (flags & kStartingWriteTLS))
	{
		flags &= ~kStartingReadTLS;
		flags &= ~kStartingWriteTLS;
		
		flags |= kSocketSecure;
		
		__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;

		if (delegateQueue && [theDelegate respondsToSelector:@selector(socketDidSecure:)])
		{
			dispatch_async(delegateQueue, ^{ @autoreleasepool {
				
				[theDelegate socketDidSecure:self];
			}});
		}
		
		[self endCurrentRead];
		[self endCurrentWrite];
		
		[self maybeDequeueRead];
		[self maybeDequeueWrite];
	}
}

- (void)cf_abortSSLHandshake:(NSError *)error
{
	LogTrace();
	
	if ((flags & kStartingReadTLS) && (flags & kStartingWriteTLS))
	{
		flags &= ~kStartingReadTLS;
		flags &= ~kStartingWriteTLS;
		
		[self closeWithError:error];
	}
}

- (void)cf_startTLS
{
	LogTrace();
	
	LogVerbose(@"Starting TLS (via CFStream)...");
	
	if ([preBuffer availableBytes] > 0)
	{
		NSString *msg = @"Invalid TLS transition. Handshake has already been read from socket.";
		
		[self closeWithError:[self otherError:msg]];
		return;
	}
	
	[self suspendReadSource];
	[self suspendWriteSource];
	
	socketFDBytesAvailable = 0;
	flags &= ~kSocketCanAcceptBytes;
	flags &= ~kSecureSocketHasBytesAvailable;
	
	flags |=  kUsingCFStreamForTLS;
	
	if (![self createReadAndWriteStream])
	{
		[self closeWithError:[self otherError:@"Error in CFStreamCreatePairWithSocket"]];
		return;
	}
	
	if (![self registerForStreamCallbacksIncludingReadWrite:YES])
	{
		[self closeWithError:[self otherError:@"Error in CFStreamSetClient"]];
		return;
	}
	
	if (![self addStreamsToRunLoop])
	{
		[self closeWithError:[self otherError:@"Error in CFStreamScheduleWithRunLoop"]];
		return;
	}
	
	NSAssert([currentRead isKindOfClass:[GCDAsyncSpecialPacket class]], @"Invalid read packet for startTLS");
	NSAssert([currentWrite isKindOfClass:[GCDAsyncSpecialPacket class]], @"Invalid write packet for startTLS");
	
	GCDAsyncSpecialPacket *tlsPacket = (GCDAsyncSpecialPacket *)currentRead;
	CFDictionaryRef tlsSettings = (__bridge CFDictionaryRef)tlsPacket->tlsSettings;
	
	// Getting an error concerning kCFStreamPropertySSLSettings ?
	// You need to add the CFNetwork framework to your iOS application.
	
	BOOL r1 = CFReadStreamSetProperty(readStream, kCFStreamPropertySSLSettings, tlsSettings);
	BOOL r2 = CFWriteStreamSetProperty(writeStream, kCFStreamPropertySSLSettings, tlsSettings);
	
	// For some reason, starting around the time of iOS 4.3,
	// the first call to set the kCFStreamPropertySSLSettings will return true,
	// but the second will return false.
	// 
	// Order doesn't seem to matter.
	// So you could call CFReadStreamSetProperty and then CFWriteStreamSetProperty, or you could reverse the order.
	// Either way, the first call will return true, and the second returns false.
	// 
	// Interestingly, this doesn't seem to affect anything.
	// Which is not altogether unusual, as the documentation seems to suggest that (for many settings)
	// setting it on one side of the stream automatically sets it for the other side of the stream.
	// 
	// Although there isn't anything in the documentation to suggest that the second attempt would fail.
	// 
	// Furthermore, this only seems to affect streams that are negotiating a security upgrade.
	// In other words, the socket gets connected, there is some back-and-forth communication over the unsecure
	// connection, and then a startTLS is issued.
	// So this mostly affects newer protocols (XMPP, IMAP) as opposed to older protocols (HTTPS).
	
	if (!r1 && !r2) // Yes, the && is correct - workaround for apple bug.
	{
		[self closeWithError:[self otherError:@"Error in CFStreamSetProperty"]];
		return;
	}
	
	if (![self openStreams])
	{
		[self closeWithError:[self otherError:@"Error in CFStreamOpen"]];
		return;
	}
	
	LogVerbose(@"Waiting for SSL Handshake to complete...");
}

#endif

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark CFStream
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

#if TARGET_OS_IPHONE
// 唤醒线程时调用
+ (void)ignore:(id)_
{}

+ (void)startCFStreamThreadIfNeeded
{
	LogTrace();
	
	static dispatch_once_t predicate;
	dispatch_once(&predicate, ^{
		
		cfstreamThreadRetainCount = 0;
		cfstreamThreadSetupQueue = dispatch_queue_create("GCDAsyncSocket-CFStreamThreadSetup", DISPATCH_QUEUE_SERIAL);
	});
	
	dispatch_sync(cfstreamThreadSetupQueue, ^{ @autoreleasepool {
		
		if (++cfstreamThreadRetainCount == 1)
		{
			cfstreamThread = [[NSThread alloc] initWithTarget:self
			                                         selector:@selector(cfstreamThread:)
			                                           object:nil];
			[cfstreamThread start];
		}
	}});
}
// 停止流的线程
+ (void)stopCFStreamThreadIfNeeded
{
	LogTrace();
	
	// The creation of the cfstreamThread is relatively expensive.
	// So we'd like to keep it available for recycling.
	// However, there's a tradeoff here, because it shouldn't remain alive forever.
	// So what we're going to do is use a little delay before taking it down.
	// This way it can be reused properly in situations where multiple sockets are continually in flux.
	// 设置30秒后移除，这是由于该线程创建的开销比较大，延时销毁方便复用
	int delayInSeconds = 30;
	dispatch_time_t when = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
	dispatch_after(when, cfstreamThreadSetupQueue, ^{ @autoreleasepool {
	#pragma clang diagnostic push
	#pragma clang diagnostic warning "-Wimplicit-retain-self"
		// 如果当前线程的计数为0，则不需要处理
		if (cfstreamThreadRetainCount == 0)
		{
			LogWarn(@"Logic error concerning cfstreamThread start / stop");
			return_from_block;
		}
		// 减少当前线程的计数，如果减少后为0了则调用取消线程，并调用忽略方法，并把线程设置为空
		if (--cfstreamThreadRetainCount == 0)
		{
			[cfstreamThread cancel]; // set isCancelled flag
			
			// wake up the thread
			// 唤醒线程
            [[self class] performSelector:@selector(ignore:)
                                 onThread:cfstreamThread
                               withObject:[NSNull null]
                            waitUntilDone:NO];
            
			cfstreamThread = nil;
		}
		
	#pragma clang diagnostic pop
	}});
}

+ (void)cfstreamThread:(id)unused { @autoreleasepool
{
	[[NSThread currentThread] setName:GCDAsyncSocketThreadName];
	
	LogInfo(@"CFStreamThread: Started");
	
	// We can't run the run loop unless it has an associated input source or a timer.
	// So we'll just create a timer that will never fire - unless the server runs for decades.
	[NSTimer scheduledTimerWithTimeInterval:[[NSDate distantFuture] timeIntervalSinceNow]
	                                 target:self
	                               selector:@selector(ignore:)
	                               userInfo:nil
	                                repeats:YES];
	
	NSThread *currentThread = [NSThread currentThread];
	NSRunLoop *currentRunLoop = [NSRunLoop currentRunLoop];
	
	BOOL isCancelled = [currentThread isCancelled];
	
	while (!isCancelled && [currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]])
	{
		isCancelled = [currentThread isCancelled];
	}
	
	LogInfo(@"CFStreamThread: Stopped");
}}

+ (void)scheduleCFStreams:(GCDAsyncSocket *)asyncSocket
{
	LogTrace();
	NSAssert([NSThread currentThread] == cfstreamThread, @"Invoked on wrong thread");
	
	CFRunLoopRef runLoop = CFRunLoopGetCurrent();
	
	if (asyncSocket->readStream)
		CFReadStreamScheduleWithRunLoop(asyncSocket->readStream, runLoop, kCFRunLoopDefaultMode);
	
	if (asyncSocket->writeStream)
		CFWriteStreamScheduleWithRunLoop(asyncSocket->writeStream, runLoop, kCFRunLoopDefaultMode);
}
// 从runloop移除流
+ (void)unscheduleCFStreams:(GCDAsyncSocket *)asyncSocket
{
	LogTrace();
	NSAssert([NSThread currentThread] == cfstreamThread, @"Invoked on wrong thread");
	
	CFRunLoopRef runLoop = CFRunLoopGetCurrent();
	
	if (asyncSocket->readStream)
		CFReadStreamUnscheduleFromRunLoop(asyncSocket->readStream, runLoop, kCFRunLoopDefaultMode);
	
	if (asyncSocket->writeStream)
		CFWriteStreamUnscheduleFromRunLoop(asyncSocket->writeStream, runLoop, kCFRunLoopDefaultMode);
}

static void CFReadStreamCallback (CFReadStreamRef stream, CFStreamEventType type, void *pInfo)
{
	GCDAsyncSocket *asyncSocket = (__bridge GCDAsyncSocket *)pInfo;
	
	switch(type)
	{
		case kCFStreamEventHasBytesAvailable:
		{
			dispatch_async(asyncSocket->socketQueue, ^{ @autoreleasepool {
				
				LogCVerbose(@"CFReadStreamCallback - HasBytesAvailable");
				
				if (asyncSocket->readStream != stream)
					return_from_block;
				
				if ((asyncSocket->flags & kStartingReadTLS) && (asyncSocket->flags & kStartingWriteTLS))
				{
					// If we set kCFStreamPropertySSLSettings before we opened the streams, this might be a lie.
					// (A callback related to the tcp stream, but not to the SSL layer).
					
					if (CFReadStreamHasBytesAvailable(asyncSocket->readStream))
					{
						asyncSocket->flags |= kSecureSocketHasBytesAvailable;
						[asyncSocket cf_finishSSLHandshake];
					}
				}
				else
				{
					asyncSocket->flags |= kSecureSocketHasBytesAvailable;
					[asyncSocket doReadData];
				}
			}});
			
			break;
		}
		default:
		{
			NSError *error = (__bridge_transfer  NSError *)CFReadStreamCopyError(stream);
			
			if (error == nil && type == kCFStreamEventEndEncountered)
			{
				error = [asyncSocket connectionClosedError];
			}
			
			dispatch_async(asyncSocket->socketQueue, ^{ @autoreleasepool {
				
				LogCVerbose(@"CFReadStreamCallback - Other");
				
				if (asyncSocket->readStream != stream)
					return_from_block;
				
				if ((asyncSocket->flags & kStartingReadTLS) && (asyncSocket->flags & kStartingWriteTLS))
				{
					[asyncSocket cf_abortSSLHandshake:error];
				}
				else
				{
					[asyncSocket closeWithError:error];
				}
			}});
			
			break;
		}
	}
	
}

static void CFWriteStreamCallback (CFWriteStreamRef stream, CFStreamEventType type, void *pInfo)
{
	GCDAsyncSocket *asyncSocket = (__bridge GCDAsyncSocket *)pInfo;
	
	switch(type)
	{
		case kCFStreamEventCanAcceptBytes:
		{
			dispatch_async(asyncSocket->socketQueue, ^{ @autoreleasepool {
				
				LogCVerbose(@"CFWriteStreamCallback - CanAcceptBytes");
				
				if (asyncSocket->writeStream != stream)
					return_from_block;
				
				if ((asyncSocket->flags & kStartingReadTLS) && (asyncSocket->flags & kStartingWriteTLS))
				{
					// If we set kCFStreamPropertySSLSettings before we opened the streams, this might be a lie.
					// (A callback related to the tcp stream, but not to the SSL layer).
					
					if (CFWriteStreamCanAcceptBytes(asyncSocket->writeStream))
					{
						asyncSocket->flags |= kSocketCanAcceptBytes;
						[asyncSocket cf_finishSSLHandshake];
					}
				}
				else
				{
					asyncSocket->flags |= kSocketCanAcceptBytes;
					[asyncSocket doWriteData];
				}
			}});
			
			break;
		}
		default:
		{
			NSError *error = (__bridge_transfer NSError *)CFWriteStreamCopyError(stream);
			
			if (error == nil && type == kCFStreamEventEndEncountered)
			{
				error = [asyncSocket connectionClosedError];
			}
			
			dispatch_async(asyncSocket->socketQueue, ^{ @autoreleasepool {
				
				LogCVerbose(@"CFWriteStreamCallback - Other");
				
				if (asyncSocket->writeStream != stream)
					return_from_block;
				
				if ((asyncSocket->flags & kStartingReadTLS) && (asyncSocket->flags & kStartingWriteTLS))
				{
					[asyncSocket cf_abortSSLHandshake:error];
				}
				else
				{
					[asyncSocket closeWithError:error];
				}
			}});
			
			break;
		}
	}
	
}
// 创建读写流
- (BOOL)createReadAndWriteStream
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	// 如果已经创建了则返回
	if (readStream || writeStream)
	{
		// Streams already created
		return YES;
	}
	// 获取socketFD，优先取IPv4
	int socketFD = (socket4FD != SOCKET_NULL) ? socket4FD : (socket6FD != SOCKET_NULL) ? socket6FD : socketUN;
	// 如果没有socketFD则无法创建
	if (socketFD == SOCKET_NULL)
	{
		// Cannot create streams without a file descriptor
		return NO;
	}
	// 如果没有连接成功也不创建
	if (![self isConnected])
	{
		// Cannot create streams until file descriptor is connected
		return NO;
	}
	
	LogVerbose(@"Creating read and write stream...");
	// 创建读写流
	CFStreamCreatePairWithSocket(NULL, (CFSocketNativeHandle)socketFD, &readStream, &writeStream);
	
	// The kCFStreamPropertyShouldCloseNativeSocket property should be false by default (for our case).
	// But let's not take any chances.
	// 设置读写流不会随着绑定的socket一起关闭
	if (readStream)
		CFReadStreamSetProperty(readStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanFalse);
	if (writeStream)
		CFWriteStreamSetProperty(writeStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanFalse);
	
	if ((readStream == NULL) || (writeStream == NULL))
	{
		LogWarn(@"Unable to create read and write stream...");
		// 如果读写流不能同时创建，则全部关闭释放
		if (readStream)
		{
			CFReadStreamClose(readStream);
			CFRelease(readStream);
			readStream = NULL;
		}
		if (writeStream)
		{
			CFWriteStreamClose(writeStream);
			CFRelease(writeStream);
			writeStream = NULL;
		}
		
		return NO;
	}
	
	return YES;
}

- (BOOL)registerForStreamCallbacksIncludingReadWrite:(BOOL)includeReadWrite
{
	LogVerbose(@"%@ %@", THIS_METHOD, (includeReadWrite ? @"YES" : @"NO"));
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	NSAssert((readStream != NULL && writeStream != NULL), @"Read/Write stream is null");
	
	streamContext.version = 0;
	streamContext.info = (__bridge void *)(self);
	streamContext.retain = nil;
	streamContext.release = nil;
	streamContext.copyDescription = nil;
	
	CFOptionFlags readStreamEvents = kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered;
	if (includeReadWrite)
		readStreamEvents |= kCFStreamEventHasBytesAvailable;
	
	if (!CFReadStreamSetClient(readStream, readStreamEvents, &CFReadStreamCallback, &streamContext))
	{
		return NO;
	}
	
	CFOptionFlags writeStreamEvents = kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered;
	if (includeReadWrite)
		writeStreamEvents |= kCFStreamEventCanAcceptBytes;
	
	if (!CFWriteStreamSetClient(writeStream, writeStreamEvents, &CFWriteStreamCallback, &streamContext))
	{
		return NO;
	}
	
	return YES;
}

- (BOOL)addStreamsToRunLoop
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	NSAssert((readStream != NULL && writeStream != NULL), @"Read/Write stream is null");
	
	if (!(flags & kAddedStreamsToRunLoop))
	{
		LogVerbose(@"Adding streams to runloop...");
		
		[[self class] startCFStreamThreadIfNeeded];
        dispatch_sync(cfstreamThreadSetupQueue, ^{
            [[self class] performSelector:@selector(scheduleCFStreams:)
                                 onThread:cfstreamThread
                               withObject:self
                            waitUntilDone:YES];
        });
		flags |= kAddedStreamsToRunLoop;
	}
	
	return YES;
}
// 从runloop移除流
- (void)removeStreamsFromRunLoop
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	NSAssert((readStream != NULL && writeStream != NULL), @"Read/Write stream is null");
	
	if (flags & kAddedStreamsToRunLoop)
	{
		LogVerbose(@"Removing streams from runloop...");
        // 如果标记了给runloop增加过流，则在流的线程执行移除
        dispatch_sync(cfstreamThreadSetupQueue, ^{
            [[self class] performSelector:@selector(unscheduleCFStreams:)
                                 onThread:cfstreamThread
                               withObject:self
                            waitUntilDone:YES];
        });
		// 停止流的线程
		[[self class] stopCFStreamThreadIfNeeded];
		// 去除标记
		flags &= ~kAddedStreamsToRunLoop;
	}
}

- (BOOL)openStreams
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	NSAssert((readStream != NULL && writeStream != NULL), @"Read/Write stream is null");
	
	CFStreamStatus readStatus = CFReadStreamGetStatus(readStream);
	CFStreamStatus writeStatus = CFWriteStreamGetStatus(writeStream);
	
	if ((readStatus == kCFStreamStatusNotOpen) || (writeStatus == kCFStreamStatusNotOpen))
	{
		LogVerbose(@"Opening read and write stream...");
		
		BOOL r1 = CFReadStreamOpen(readStream);
		BOOL r2 = CFWriteStreamOpen(writeStream);
		
		if (!r1 || !r2)
		{
			LogError(@"Error in CFStreamOpen");
			return NO;
		}
	}
	
	return YES;
}

#endif

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Advanced
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * See header file for big discussion of this method.
**/
- (BOOL)autoDisconnectOnClosedReadStream
{
	// Note: YES means kAllowHalfDuplexConnection is OFF
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		return ((config & kAllowHalfDuplexConnection) == 0);
	}
	else
	{
		__block BOOL result;
		
		dispatch_sync(socketQueue, ^{
            result = ((self->config & kAllowHalfDuplexConnection) == 0);
		});
		
		return result;
	}
}

/**
 * See header file for big discussion of this method.
**/
- (void)setAutoDisconnectOnClosedReadStream:(BOOL)flag
{
	// Note: YES means kAllowHalfDuplexConnection is OFF
	
	dispatch_block_t block = ^{
		
		if (flag)
            self->config &= ~kAllowHalfDuplexConnection;
		else
            self->config |= kAllowHalfDuplexConnection;
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_async(socketQueue, block);
}


/**
 * See header file for big discussion of this method.
**/
- (void)markSocketQueueTargetQueue:(dispatch_queue_t)socketNewTargetQueue
{
	void *nonNullUnusedPointer = (__bridge void *)self;
	dispatch_queue_set_specific(socketNewTargetQueue, IsOnSocketQueueOrTargetQueueKey, nonNullUnusedPointer, NULL);
}

/**
 * See header file for big discussion of this method.
**/
- (void)unmarkSocketQueueTargetQueue:(dispatch_queue_t)socketOldTargetQueue
{
	dispatch_queue_set_specific(socketOldTargetQueue, IsOnSocketQueueOrTargetQueueKey, NULL, NULL);
}

/**
 * See header file for big discussion of this method.
**/
- (void)performBlock:(dispatch_block_t)block
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
}

/**
 * Questions? Have you read the header file?
**/
- (int)socketFD
{
	if (!dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		LogWarn(@"%@ - Method only available from within the context of a performBlock: invocation", THIS_METHOD);
		return SOCKET_NULL;
	}
	
	if (socket4FD != SOCKET_NULL)
		return socket4FD;
	else
		return socket6FD;
}

/**
 * Questions? Have you read the header file?
**/
- (int)socket4FD
{
	if (!dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		LogWarn(@"%@ - Method only available from within the context of a performBlock: invocation", THIS_METHOD);
		return SOCKET_NULL;
	}
	
	return socket4FD;
}

/**
 * Questions? Have you read the header file?
**/
- (int)socket6FD
{
	if (!dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		LogWarn(@"%@ - Method only available from within the context of a performBlock: invocation", THIS_METHOD);
		return SOCKET_NULL;
	}
	
	return socket6FD;
}

#if TARGET_OS_IPHONE

/**
 * Questions? Have you read the header file?
**/
- (CFReadStreamRef)readStream
{
	if (!dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		LogWarn(@"%@ - Method only available from within the context of a performBlock: invocation", THIS_METHOD);
		return NULL;
	}
	
	if (readStream == NULL)
		[self createReadAndWriteStream];
	
	return readStream;
}

/**
 * Questions? Have you read the header file?
**/
- (CFWriteStreamRef)writeStream
{
	if (!dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		LogWarn(@"%@ - Method only available from within the context of a performBlock: invocation", THIS_METHOD);
		return NULL;
	}
	
	if (writeStream == NULL)
		[self createReadAndWriteStream];
	
	return writeStream;
}

- (BOOL)enableBackgroundingOnSocketWithCaveat:(BOOL)caveat
{
	if (![self createReadAndWriteStream])
	{
		// Error occurred creating streams (perhaps socket isn't open)
		return NO;
	}
	
	BOOL r1, r2;
	
	LogVerbose(@"Enabling backgrouding on socket");
	
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	r1 = CFReadStreamSetProperty(readStream, kCFStreamNetworkServiceType, kCFStreamNetworkServiceTypeVoIP);
	r2 = CFWriteStreamSetProperty(writeStream, kCFStreamNetworkServiceType, kCFStreamNetworkServiceTypeVoIP);
#pragma clang diagnostic pop

	if (!r1 || !r2)
	{
		return NO;
	}
	
	if (!caveat)
	{
		if (![self openStreams])
		{
			return NO;
		}
	}
	
	return YES;
}

/**
 * Questions? Have you read the header file?
**/
- (BOOL)enableBackgroundingOnSocket
{
	LogTrace();
	
	if (!dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		LogWarn(@"%@ - Method only available from within the context of a performBlock: invocation", THIS_METHOD);
		return NO;
	}
	
	return [self enableBackgroundingOnSocketWithCaveat:NO];
}

- (BOOL)enableBackgroundingOnSocketWithCaveat // Deprecated in iOS 4.???
{
	// This method was created as a workaround for a bug in iOS.
	// Apple has since fixed this bug.
	// I'm not entirely sure which version of iOS they fixed it in...
	
	LogTrace();
	
	if (!dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		LogWarn(@"%@ - Method only available from within the context of a performBlock: invocation", THIS_METHOD);
		return NO;
	}
	
	return [self enableBackgroundingOnSocketWithCaveat:YES];
}

#endif

- (SSLContextRef)sslContext
{
	if (!dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		LogWarn(@"%@ - Method only available from within the context of a performBlock: invocation", THIS_METHOD);
		return NULL;
	}
	
	return sslContext;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Class Utilities
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// 通过host和端口获取地址组，域名解析
+ (NSMutableArray *)lookupHost:(NSString *)host port:(uint16_t)port error:(NSError **)errPtr
{
	LogTrace();
	
	NSMutableArray *addresses = nil;
	NSError *error = nil;
	
	if ([host isEqualToString:@"localhost"] || [host isEqualToString:@"loopback"])
	{
		// 如果是localhost或环回地址，则返回对应的IPv4和IPv6的地址
		// Use LOOPBACK address
		struct sockaddr_in nativeAddr4;
		nativeAddr4.sin_len         = sizeof(struct sockaddr_in);
		nativeAddr4.sin_family      = AF_INET;
		nativeAddr4.sin_port        = htons(port);
		nativeAddr4.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		memset(&(nativeAddr4.sin_zero), 0, sizeof(nativeAddr4.sin_zero));
		
		struct sockaddr_in6 nativeAddr6;
		nativeAddr6.sin6_len        = sizeof(struct sockaddr_in6);
		nativeAddr6.sin6_family     = AF_INET6;
		nativeAddr6.sin6_port       = htons(port);
		nativeAddr6.sin6_flowinfo   = 0;
		nativeAddr6.sin6_addr       = in6addr_loopback;
		nativeAddr6.sin6_scope_id   = 0;
		
		// Wrap the native address structures
		
		NSData *address4 = [NSData dataWithBytes:&nativeAddr4 length:sizeof(nativeAddr4)];
		NSData *address6 = [NSData dataWithBytes:&nativeAddr6 length:sizeof(nativeAddr6)];
		
		addresses = [NSMutableArray arrayWithCapacity:2];
		[addresses addObject:address4];
		[addresses addObject:address6];
	}
	else
	{
		// 如果不是localhost或环回地址，先取端口号字符串
		NSString *portStr = [NSString stringWithFormat:@"%hu", port];
		
		struct addrinfo hints, *res, *res0;
		// 初始化地址信息为未指定地址类型、socket、tcp
		memset(&hints, 0, sizeof(hints));
		hints.ai_family   = PF_UNSPEC;
		hints.ai_socktype = SOCK_STREAM;
		hints.ai_protocol = IPPROTO_TCP;
		// 根据host和端口创建一个sockaddr结构的链表
		int gai_error = getaddrinfo([host UTF8String], [portStr UTF8String], &hints, &res0);
		
		if (gai_error)
		{
			// 设置失败，声明错误
			error = [self gaiError:gai_error];
		}
		else
		{
			// 设置成功，则遍历链表，找出IPv4和IPv6地址的总数
			NSUInteger capacity = 0;
			for (res = res0; res; res = res->ai_next)
			{
				if (res->ai_family == AF_INET || res->ai_family == AF_INET6) {
					capacity++;
				}
			}
			// 声明对应大小的数组
			addresses = [NSMutableArray arrayWithCapacity:capacity];
			// 遍历链表
			for (res = res0; res; res = res->ai_next)
			{
				if (res->ai_family == AF_INET)
				{
					// Found IPv4 address.
					// Wrap the native address structure, and add to results.
					// 获取IPv4地址并加入数组
					NSData *address4 = [NSData dataWithBytes:res->ai_addr length:res->ai_addrlen];
					[addresses addObject:address4];
				}
				else if (res->ai_family == AF_INET6)
				{
					// Fixes connection issues with IPv6
					// https://github.com/robbiehanson/CocoaAsyncSocket/issues/429#issuecomment-222477158
					
					// Found IPv6 address.
					// Wrap the native address structure, and add to results.
					// 获取IPv6地址，在转换端口号为网络字节序后，加入数组
					struct sockaddr_in6 *sockaddr = (struct sockaddr_in6 *)(void *)res->ai_addr;
					in_port_t *portPtr = &sockaddr->sin6_port;
					if ((portPtr != NULL) && (*portPtr == 0)) {
					        *portPtr = htons(port);
					}

					NSData *address6 = [NSData dataWithBytes:res->ai_addr length:res->ai_addrlen];
					[addresses addObject:address6];
				}
			}
			//释放
			freeaddrinfo(res0);
			// 如果没获取到则报错
			if ([addresses count] == 0)
			{
				error = [self gaiError:EAI_FAIL];
			}
		}
	}
	
	if (errPtr) *errPtr = error;
	return addresses;
}
// 返回本机序的socket4地址
+ (NSString *)hostFromSockaddr4:(const struct sockaddr_in *)pSockaddr4
{
	char addrBuf[INET_ADDRSTRLEN];
	
	if (inet_ntop(AF_INET, &pSockaddr4->sin_addr, addrBuf, (socklen_t)sizeof(addrBuf)) == NULL)
	{
		addrBuf[0] = '\0';
	}
	
	return [NSString stringWithCString:addrBuf encoding:NSASCIIStringEncoding];
}
// 返回本机序的socket6地址
+ (NSString *)hostFromSockaddr6:(const struct sockaddr_in6 *)pSockaddr6
{
	char addrBuf[INET6_ADDRSTRLEN];
	
	if (inet_ntop(AF_INET6, &pSockaddr6->sin6_addr, addrBuf, (socklen_t)sizeof(addrBuf)) == NULL)
	{
		addrBuf[0] = '\0';
	}
	
	return [NSString stringWithCString:addrBuf encoding:NSASCIIStringEncoding];
}
// 返回本机序的socket4地址端口号
+ (uint16_t)portFromSockaddr4:(const struct sockaddr_in *)pSockaddr4
{
	return ntohs(pSockaddr4->sin_port);
}
// 返回本机序的socket6地址端口号
+ (uint16_t)portFromSockaddr6:(const struct sockaddr_in6 *)pSockaddr6
{
	return ntohs(pSockaddr6->sin6_port);
}

+ (NSURL *)urlFromSockaddrUN:(const struct sockaddr_un *)pSockaddr
{
	NSString *path = [NSString stringWithUTF8String:pSockaddr->sun_path];
	return [NSURL fileURLWithPath:path];
}

+ (NSString *)hostFromAddress:(NSData *)address
{
	NSString *host;
	
	if ([self getHost:&host port:NULL fromAddress:address])
		return host;
	else
		return nil;
}

+ (uint16_t)portFromAddress:(NSData *)address
{
	uint16_t port;
	
	if ([self getHost:NULL port:&port fromAddress:address])
		return port;
	else
		return 0;
}

+ (BOOL)isIPv4Address:(NSData *)address
{
	if ([address length] >= sizeof(struct sockaddr))
	{
		const struct sockaddr *sockaddrX = [address bytes];
		
		if (sockaddrX->sa_family == AF_INET) {
			return YES;
		}
	}
	
	return NO;
}

+ (BOOL)isIPv6Address:(NSData *)address
{
	if ([address length] >= sizeof(struct sockaddr))
	{
		const struct sockaddr *sockaddrX = [address bytes];
		
		if (sockaddrX->sa_family == AF_INET6) {
			return YES;
		}
	}
	
	return NO;
}

+ (BOOL)getHost:(NSString **)hostPtr port:(uint16_t *)portPtr fromAddress:(NSData *)address
{
	return [self getHost:hostPtr port:portPtr family:NULL fromAddress:address];
}

+ (BOOL)getHost:(NSString **)hostPtr port:(uint16_t *)portPtr family:(sa_family_t *)afPtr fromAddress:(NSData *)address
{
	if ([address length] >= sizeof(struct sockaddr))
	{
		const struct sockaddr *sockaddrX = [address bytes];
		
		if (sockaddrX->sa_family == AF_INET)
		{
			if ([address length] >= sizeof(struct sockaddr_in))
			{
				struct sockaddr_in sockaddr4;
				memcpy(&sockaddr4, sockaddrX, sizeof(sockaddr4));
				
				if (hostPtr) *hostPtr = [self hostFromSockaddr4:&sockaddr4];
				if (portPtr) *portPtr = [self portFromSockaddr4:&sockaddr4];
				if (afPtr)   *afPtr   = AF_INET;
				
				return YES;
			}
		}
		else if (sockaddrX->sa_family == AF_INET6)
		{
			if ([address length] >= sizeof(struct sockaddr_in6))
			{
				struct sockaddr_in6 sockaddr6;
				memcpy(&sockaddr6, sockaddrX, sizeof(sockaddr6));
				
				if (hostPtr) *hostPtr = [self hostFromSockaddr6:&sockaddr6];
				if (portPtr) *portPtr = [self portFromSockaddr6:&sockaddr6];
				if (afPtr)   *afPtr   = AF_INET6;
				
				return YES;
			}
		}
	}
	
	return NO;
}

+ (NSData *)CRLFData
{
	return [NSData dataWithBytes:"\x0D\x0A" length:2];
}

+ (NSData *)CRData
{
	return [NSData dataWithBytes:"\x0D" length:1];
}

+ (NSData *)LFData
{
	return [NSData dataWithBytes:"\x0A" length:1];
}

+ (NSData *)ZeroData
{
	return [NSData dataWithBytes:"" length:1];
}

@end	
