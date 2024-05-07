#include "info.h"
#import <Foundation/Foundation.h>
#import "util.h"
#import <sys/stat.h>

NSString *NSJBRootPath(NSString *relativePath)
{
	@autoreleasepool {
		return [[NSString stringWithUTF8String:jbinfo(rootPath)] stringByAppendingPathComponent:relativePath];
	}
}

NSString *NSPrebootUUIDPath(NSString *relativePath)
{
	@autoreleasepool {
		return [NSString stringWithUTF8String:prebootUUIDPath(relativePath.UTF8String)];
	}
}