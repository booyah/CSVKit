//
//  CSVKit.m
//  CSVKit
//
//  Copyright (c) 2011 Booyah, Inc.
//
//  Permission is hereby granted, free of charge, to any person obtaining a
//  copy of this software and associated documentation files (the "Software"),
//  to deal in the Software without restriction, including without limitation
//  the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  and/or sell copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included
//  in all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//
//  Authors:
//  Jon Parise <jon@booyah.com>
//

#import "CSVKit.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>

#include <CoreFoundation/CFArray.h>
#include <CoreFoundation/CFNumber.h>
#include <CoreFoundation/CFString.h>

#import <Foundation/NSArray.h>
#import <Foundation/NSData.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSError.h>
#import <Foundation/NSException.h>
#import <Foundation/NSKeyValueCoding.h>
#import <Foundation/NSString.h>

#if defined (__GNUC__) && (__GNUC__ >= 4)
#define CSV_ATTRIBUTES(attr, ...)       __attribute__((attr, ##__VA_ARGS__))
#define CSV_EXPECTED(cond, expect)      __builtin_expect((long)(cond), (expect))
#define CSV_LIKELY(cond)                CSV_EXPECTED(cond, 1U)
#define CSV_UNLIKELY(cond)              CSV_EXPECTED(cond, 0U)
#else
#define CSV_ATTRIBUTES(attr, ...)
#define CSV_EXPECTED(cond, expect)      (cond)
#define CSV_LIKELY(cond)                (cond)
#define CSV_UNLIKELY(cond)              (cond)
#endif // defined (__GNUC__) && (__GNUC__ >= 4)

#define CSV_STATIC_INLINE   static __inline__ CSV_ATTRIBUTES(always_inline)

#define CSV_MAX_FIELD_LENGTH    (128UL * 1024UL)
#define CSV_DEFAULT_BUFFER_SIZE (4096UL)

typedef enum
{
    CSVParserStateStartRecord,
    CSVParserStateStartField,
    CSVParserStateEscapedChar,
    CSVParserStateInField,
    CSVParserStateInQuotedField,
    CSVParserStateEscapeInQuotedField,
    CSVParserStateQuoteInQuotedField,
    CSVParserStateEatCRLF,
} CSVParserState;

typedef enum
{
    CSVFieldTypeString,
    CSVFieldTypeNumber,
} CSVFieldType;

enum
{
    CSVManagedBufferOnStack     = (1 << 0),
    CSVManagedBufferOnHeap      = (1 << 1),

    CSVManagedBufferFreeMask     = CSVManagedBufferOnHeap,
    CSVManagedBufferLocationMask = CSVManagedBufferOnStack | CSVManagedBufferOnHeap,
};

typedef struct
{
    unsigned char * bytes;
    size_t          capacity;
    size_t          length;
    NSUInteger      flags;
} CSVManagedBuffer;

typedef void (^CSVFieldBlock)(NSUInteger index, CSVManagedBuffer *buffer, CSVFieldType type, BOOL *stop);

struct CSVParserContext
{
    const CSVDialect *  dialect;        // Current parsing dialect
    CSVParserState      state;          // Current parser state
    CSVManagedBuffer    field;          // Current field buffer
    CSVFieldType        fieldType;      // Current field type
    NSUInteger          fieldNumber;    // Current field number
    NSUInteger          lineNumber;     // Source text line number
    CSVFieldBlock       fieldBlock;     // Field handler block
    NSError *           error;          // Parsing error
};

#pragma mark Dialects

const CSVDialect CSVExcelDialect =
{
    .delimiter = ',',
    .quoteChar = '"',
    .escapeChar = 0,
    .doubleQuote = YES,
    .skipInitialSpace = NO,
    .strict = NO,
    .quoteStyle = CSVQuoteStyleMinimal,
};

const CSVDialect CSVExcelTabDialect =
{
    .delimiter = '\t',
    .quoteChar = '"',
    .escapeChar = 0,
    .doubleQuote = YES,
    .skipInitialSpace = NO,
    .strict = NO,
    .quoteStyle = CSVQuoteStyleMinimal,
};

#pragma mark Errors

NSString * const CSVErrorDomain = @"CSVErrorDomain";
NSString * const CSVLineNumberKey = @"CSVLineNumberKey";
NSString * const CSVFieldNumberKey = @"CSVFieldNumberKey";

static void csv_error(CSVParserContext *context, NSString *format, ...)
{
    if (context->error == nil)
    {
        va_list args;
        va_start(args, format);
        NSString *description = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);

        NSNumber *lineNumber = [NSNumber numberWithUnsignedLong:context->lineNumber];
        NSNumber *fieldNumber = [NSNumber numberWithUnsignedLong:context->fieldNumber];

        NSDictionary *details = [NSDictionary dictionaryWithObjectsAndKeys:
                                 description, NSLocalizedDescriptionKey,
                                 lineNumber, CSVLineNumberKey,
                                 fieldNumber, CSVFieldNumberKey,
                                 nil];

        context->error = [NSError errorWithDomain:CSVErrorDomain
                                             code:-1
                                         userInfo:details];

        [description release];
    }
}

#pragma mark Buffer Management

static void csv_buffer_free(CSVManagedBuffer * const buffer)
{
    if (buffer->bytes && buffer->flags & CSVManagedBufferFreeMask)
        free(buffer->bytes);

    buffer->bytes    = NULL;
    buffer->capacity = 0UL;
    buffer->length   = 0UL;
}

static void csv_buffer_stack(CSVManagedBuffer * const buffer, unsigned char *ptr, size_t size)
{
    csv_buffer_free(buffer);
    buffer->bytes    = ptr;
    buffer->capacity = size;
    buffer->length   = 0UL;
    buffer->flags    = (buffer->flags & ~CSVManagedBufferLocationMask) | CSVManagedBufferOnStack;
}

static unsigned char * csv_buffer_grow(CSVManagedBuffer * const buffer)
{
    if (buffer->capacity > 0)
    {
        // We can't grow beyond INT_MAX capacity.
        if (CSV_UNLIKELY(buffer->capacity > INT_MAX / 2))
            return NULL;

        buffer->capacity *= 2;
    }
    else
    {
        // New buffers default to the heap.
        buffer->capacity = CSV_DEFAULT_BUFFER_SIZE;
        buffer->flags    = (buffer->flags & ~CSVManagedBufferLocationMask) | CSVManagedBufferOnHeap;
    }

    // Stack-based buffers are always converted to heap-based buffers.
    if (buffer->flags & CSVManagedBufferOnStack)
    {
        unsigned char *ptr = malloc(buffer->capacity);
        if (CSV_UNLIKELY(ptr == NULL))
            return NULL;

        buffer->bytes = memcpy(ptr, buffer->bytes, buffer->length);
        buffer->flags = (buffer->flags & ~CSVManagedBufferLocationMask) | CSVManagedBufferOnHeap;
    }

    // Heap-based buffers are reallocated to the new size.
    else if (buffer->flags & CSVManagedBufferOnHeap)
    {
        buffer->bytes = reallocf(buffer->bytes, buffer->capacity);
    }

    return buffer->bytes;
}

#pragma mark Parsing

static id csv_parser_field_object(const CSVManagedBuffer *buffer, CSVFieldType type)
{
    id object = nil;

    switch (type)
    {
        case CSVFieldTypeString:
            object = (id)CFStringCreateWithBytes(NULL, buffer->bytes, buffer->length,
                                                 kCFStringEncodingUTF8, NO);
            break;

        case CSVFieldTypeNumber:
        {
            unsigned char  number[buffer->length + 1UL];
            unsigned char *numberEnd = NULL;

            memcpy(number, buffer->bytes, buffer->length);
            number[buffer->length] = '\0';

            double doubleValue = strtod((const char *)number, (char **)&numberEnd);
            object = (id)CFNumberCreate(NULL, kCFNumberDoubleType, &doubleValue);
            break;
        }
    }

    return object;
}

static void csv_parser_free(CSVParserContext *context)
{
    csv_buffer_free(&context->field);
}

static int csv_parser_add_field(CSVParserContext *context)
{
    BOOL stop = NO;
    context->fieldBlock(context->fieldNumber, &context->field, context->fieldType, &stop);
    if (CSV_UNLIKELY(stop))
        return -1;

    // Reset current field.
    context->field.length = 0UL;
    context->fieldType = CSVFieldTypeString;
    context->fieldNumber++;

    return 0;
}

static int csv_parser_add_char(CSVParserContext *context, unsigned char c)
{
    CSVManagedBuffer * const buffer = &context->field;

    if (CSV_UNLIKELY(buffer->length >= CSV_MAX_FIELD_LENGTH))
    {
        csv_error(context, @"Field length exceeds limit (%lu)", CSV_MAX_FIELD_LENGTH);
        return -1;
    }

    if (CSV_UNLIKELY((buffer->length == buffer->capacity) && !csv_buffer_grow(buffer)))
    {
        csv_error(context, @"Failed to grow field buffer beyond %lu bytes", buffer->capacity);
        return -1;
    }

    buffer->bytes[buffer->length++] = c;

    return 0;
}

static int csv_parser_process_char(CSVParserContext *context, unsigned char c)
{
    const CSVDialect * const dialect = context->dialect;

    switch (context->state)
    {
        case CSVParserStateStartRecord:
            if (c == '\0')
            {
                // Empty line
                break;
            }
            else if (c == '\n' || c == '\r')
            {
                context->state = CSVParserStateEatCRLF;
            }

            // Normal character starting a field
            context->state = CSVParserStateStartField;
            /* FALLTHROUGH */

        case CSVParserStateStartField:
            if (c == '\n' || c == '\r' || c == '\0')
            {
                // Empty field
                if (CSV_UNLIKELY(csv_parser_add_field(context) < 0))
                    return -1;

                context->state = (c == '\0') ? CSVParserStateStartRecord : CSVParserStateEatCRLF;
            }
            else if (c == dialect->quoteChar && dialect->quoteStyle)
            {
                // Start of a quoted field
                context->state = CSVParserStateInQuotedField;
            }
            else if (c == dialect->escapeChar)
            {
                // Possible escaped character
                context->state = CSVParserStateEscapedChar;
            }
            else if (c == ' ' && dialect->skipInitialSpace)
            {
                // Ignore space at the start of a field
                break;
            }
            else if (c == dialect->delimiter)
            {
                // Empty field
                if (CSV_UNLIKELY(csv_parser_add_field(context) < 0))
                    return -1;
            }
            else
            {
                // Begin a new unquoted field
                if (dialect->quoteStyle == CSVQuoteStyleNonNumeric)
                    context->fieldType = CSVFieldTypeNumber;

                if (CSV_UNLIKELY(csv_parser_add_char(context, c) < 0))
                    return -1;

                context->state = CSVParserStateInField;
            }
            break;

        case CSVParserStateEscapedChar:
            if (c == '\0')
                c = '\n';

            if (CSV_UNLIKELY(csv_parser_add_char(context, c) < 0))
                return -1;

            context->state = CSVParserStateInField;
            break;

        case CSVParserStateInField:
            if (c == '\n' || c == '\r' || c == '\0')
            {
                if (CSV_UNLIKELY(csv_parser_add_field(context) < 0))
                    return -1;

                context->state = (c == '\0') ? CSVParserStateStartRecord : CSVParserStateEatCRLF;
            }
            else if (c == dialect->escapeChar)
            {
                // Possible escaped character
                context->state = CSVParserStateEscapedChar;
            }
            else if (c == dialect->delimiter)
            {
                // Add current field and wait for a new field
                if (CSV_UNLIKELY(csv_parser_add_field(context) < 0))
                    return -1;

                context->state = CSVParserStateStartField;
            }
            else
            {
                // Add normal character to the current field
                if (CSV_UNLIKELY(csv_parser_add_char(context, c) < 0))
                    return -1;
            }
            break;

        case CSVParserStateInQuotedField:
            if (c == '\0')
            {
                break;
            }
            else if (c == dialect->escapeChar)
            {
                // Possible escape character
                context->state = CSVParserStateEscapeInQuotedField;
            }
            else if (c == dialect->quoteChar && dialect->quoteStyle)
            {
                if (dialect->doubleQuote)
                {
                    // Doublequote: " represented by ""
                    context->state = CSVParserStateQuoteInQuotedField;
                }
                else
                {
                    // End of quote part of field
                    context->state = CSVParserStateInField;
                }
            }
            else
            {
                // Add normal character to field
                if (CSV_UNLIKELY(csv_parser_add_char(context, c) < 0))
                    return -1;
            }
            break;

        case CSVParserStateEscapeInQuotedField:
            if (c == '\0')
                c = '\n';

            if (CSV_UNLIKELY(csv_parser_add_char(context, c) < 0))
                return -1;

            context->state = CSVParserStateInQuotedField;
            break;
            
        case CSVParserStateQuoteInQuotedField:
            // Doublequote - quote in a quoted field
            if (c == dialect->quoteChar && dialect->quoteStyle)
            {
                // Save "" as "
                if (CSV_UNLIKELY(csv_parser_add_char(context, c) < 0))
                    return -1;

                context->state = CSVParserStateInQuotedField;
            }
            else if (c == dialect->delimiter)
            {
                // Add current field and wait for new field
                if (CSV_UNLIKELY(csv_parser_add_field(context) < 0))
                    return -1;

                context->state = CSVParserStateStartField;
            }
            else if (c == '\n' || c == '\r' || c == '\0')
            {
                // End of line
                if (CSV_UNLIKELY(csv_parser_add_field(context) < 0))
                    return -1;

                context->state = (c == '\0') ? CSVParserStateStartRecord : CSVParserStateEatCRLF;
            }
            else if (!dialect->strict)
            {
                if (CSV_UNLIKELY(csv_parser_add_char(context, c) < 0))
                    return -1;

                context->state = CSVParserStateInField;
            }
            else
            {
                csv_error(context, @"'%c' expected after '%c'", dialect->delimiter, dialect->quoteChar);
                return -1;
            }
            break;

        case CSVParserStateEatCRLF:
            if (c == '\n' || c == '\r')
            {
                // Simply consume the character.
                break;
            }
            else if (c == '\0')
            {
                context->state = CSVParserStateStartRecord;
            }
            else
            {
                csv_error(context, @"Newline character seen in unquoted field");
                return -1;
            }
            break;
    }

    return 0;
}

static int csv_parser_parse_line(CSVParserContext *context, const unsigned char *line, size_t length)
{
    context->state = CSVParserStateStartRecord;
    context->field.length = 0UL;
    context->fieldType = CSVFieldTypeString;
    context->fieldNumber = 0;
    context->lineNumber++;

    while (length--)
    {
        unsigned char c = *line++;
        if (CSV_UNLIKELY(c == '\0'))
        {
            csv_error(context, @"Line contains NUL byte");
            return -1;
        }

        if (CSV_UNLIKELY(csv_parser_process_char(context, c) < 0))
            return -1;
    }

    // Finalize the line.
    if (CSV_UNLIKELY(csv_parser_process_char(context, '\0') < 0))
        return -1;

    BOOL stop = NO;
    context->fieldBlock(NSUIntegerMax, NULL, CSVFieldTypeString, &stop);
    if (CSV_UNLIKELY(stop))
        return -1;

    return 0;
}

static int csv_parser_parse_data(CSVParserContext *context, const unsigned char *data, size_t size)
{
    const unsigned char * const dataEnd = data + size;
    const unsigned char * line = data;
    BOOL skipNextNewline = NO;

    // TODO: Consider replacing this "universal" newline detection with a
    //       pre-determined line separator defined by the current dialect.

    for (const unsigned char *p = data; p < dataEnd; ++p)
    {
        unsigned char c = *p;

        if (skipNextNewline)
        {
            skipNextNewline = NO;
            if (c == '\n')
                continue;
        }

        if (c == '\r')
        {
            skipNextNewline = YES;
            c = '\n';
        }

        // End of line.
        if (c == '\n')
        {
            if (CSV_UNLIKELY(csv_parser_parse_line(context, line, p - line) < 0))
                return -1;

            line = NULL;
        }
        else if (line == NULL)
        {
            line = p;
        }
    }

    // The last line may not have ended in a line sepatator so we still have
    // some remaining characters to parse.
    if (CSV_UNLIKELY(line && csv_parser_parse_line(context, line, dataEnd - line) < 0))
        return -1;

    return 0;
}

#pragma mark -

@implementation CSVParser

+ (id)parser
{
    return [self parserWithDialect:nil];
}

+ (id)parserWithDialect:(const CSVDialect *)dialect
{
    return [[[self alloc] initWithDialect:dialect] autorelease];
}

- (id)init
{
    return [self initWithDialect:nil];
}

- (id)initWithDialect:(const CSVDialect *)dialect
{
    // Default to the Excel dialect.
    if (dialect == nil)
    {
        dialect = &CSVExcelDialect;
    }

    if ((self = [super init]))
    {
        context = (CSVParserContext *)calloc(1, sizeof(CSVParserContext));
        if (CSV_UNLIKELY(context == NULL))
        {
            [self autorelease];
            return nil;
        }

        context->dialect = dialect;

        unsigned char fieldStackBuffer[CSV_DEFAULT_BUFFER_SIZE];
        csv_buffer_stack(&context->field, fieldStackBuffer, sizeof(fieldStackBuffer));
    }

    return self;
}

- (void)dealloc
{
    if (context)
    {
        csv_parser_free(context);
        context = NULL;
    }
    [super dealloc];
}

#pragma mark Field Parsing

- (BOOL)parseFieldsFromData:(NSData *)data
                      block:(void (^)(id value, NSUInteger index, BOOL *stop))block
{
    return [self parseFieldsFromData:data block:block error:nil];
}

- (BOOL)parseFieldsFromData:(NSData *)data
                      block:(void (^)(id value, NSUInteger index, BOOL *stop))block
                      error:(NSError **)error
{
    const unsigned char * const bytes = (const unsigned char *)[data bytes];
    return [self parseFieldsFromUTF8String:bytes length:[data length] block:block error:error];
}

- (BOOL)parseFieldsFromString:(NSString *)string
                        block:(void (^)(id value, NSUInteger index, BOOL *stop))block
{
    return [self parseFieldsFromString:string block:block error:nil];
}

- (BOOL)parseFieldsFromString:(NSString *)string
                        block:(void (^)(id value, NSUInteger index, BOOL *stop))block
                        error:(NSError **)error
{
    // TODO: Use an intermediate data buffer for the character encoding conversion.

    return [self parseFieldsFromUTF8String:(const unsigned char *)[string UTF8String]
                                    length:[string lengthOfBytesUsingEncoding:NSUTF8StringEncoding]
                                     block:block
                                     error:error];
}

- (BOOL)parseFieldsFromUTF8String:(const unsigned char *)string
                           length:(NSUInteger)length
                            block:(void (^)(id value, NSUInteger index, BOOL *stop))block
{
    return [self parseFieldsFromUTF8String:string length:length block:block error:nil];
}

- (BOOL)parseFieldsFromUTF8String:(const unsigned char *)string
                           length:(NSUInteger)length
                            block:(void (^)(id value, NSUInteger index, BOOL *stop))block
                            error:(NSError **)error
{
    NSParameterAssert(string != NULL);
    NSParameterAssert(block != NULL);

    context->fieldBlock = ^(NSUInteger index, CSVManagedBuffer *buffer, CSVFieldType type, BOOL *stop)
    {
        if (index != NSUIntegerMax)
        {
            id object = csv_parser_field_object(buffer, type);
            block(object, index, stop);
            CFRelease(object);
        }
        else
        {
            block(nil, NSUIntegerMax, stop);
        }
    };

    if (CSV_UNLIKELY(csv_parser_parse_data(context, string, length) < 0))
    {
        if (error)
            *error = [context->error retain];
        return NO;
    }

    return YES;    
}

#pragma mark Row Parsing

- (BOOL)parseRowsFromData:(NSData *)data
                    block:(void (^)(NSArray *, BOOL *))block
{
    return [self parseRowsFromData:data block:block error:nil];
}

- (BOOL)parseRowsFromData:(NSData *)data
                    block:(void (^)(NSArray *, BOOL *))block
                    error:(NSError **)error
{
    const unsigned char * const bytes = (const unsigned char *)[data bytes];
    return [self parseRowsFromUTF8String:bytes length:[data length] block:block error:error];
}

- (BOOL)parseRowsFromString:(NSString *)string
                      block:(void (^)(NSArray *row, BOOL *stop))block
{
    return [self parseRowsFromString:string block:block error:nil];
}

- (BOOL)parseRowsFromString:(NSString *)string
                      block:(void (^)(NSArray *row, BOOL *stop))block
                      error:(NSError **)error
{
    // TODO: Use an intermediate data buffer for the character encoding conversion.

    return [self parseRowsFromUTF8String:(const unsigned char *)[string UTF8String]
                                  length:[string lengthOfBytesUsingEncoding:NSUTF8StringEncoding]
                                   block:block error:error];
}

- (BOOL)parseRowsFromUTF8String:(const unsigned char *)string
                         length:(NSUInteger)length
                          block:(void (^)(NSArray *row, BOOL *stop))block
{
    return [self parseRowsFromUTF8String:string length:length block:block error:nil];
}

- (BOOL)parseRowsFromUTF8String:(const unsigned char *)string
                         length:(NSUInteger)length
                          block:(void (^)(NSArray *row, BOOL *stop))block
                          error:(NSError **)error
{
    NSParameterAssert(string != NULL);
    NSParameterAssert(block != NULL);

    CFMutableArrayRef row = CFArrayCreateMutable(NULL, 8, &kCFTypeArrayCallBacks);

    BOOL success = [self parseFieldsFromUTF8String:string length:length block:^(id value, NSUInteger index, BOOL *stop) {
        if (index != NSUIntegerMax)
        {
            CFArrayAppendValue(row, value);
        }
        else
        {
            CFArrayRef rowCopy = CFArrayCreateCopy(NULL, (CFArrayRef)row);
            block((NSArray *)rowCopy, stop);
            CFRelease(rowCopy);
            CFArrayRemoveAllValues(row);
        }
    } error:error];

    CFRelease(row);

    return success;
}

#pragma mark Convenience Methods

- (NSArray *)rowsFromData:(NSData *)data
{
    return [self rowsFromData:data error:nil];
}

- (NSArray *)rowsFromData:(NSData *)data error:(NSError **)error
{
    const unsigned char * const bytes = (const unsigned char *)[data bytes];
    return [self rowsFromUTF8String:bytes length:[data length] error:error];
}

- (NSArray *)rowsFromString:(NSString *)string
{
    return [self rowsFromString:string error:nil];
}

- (NSArray *)rowsFromString:(NSString *)string error:(NSError **)error
{
    // TODO: Use an intermediate data buffer for the character encoding conversion.

    return [self rowsFromUTF8String:(const unsigned char *)[string UTF8String]
                             length:[string lengthOfBytesUsingEncoding:NSUTF8StringEncoding]
                              error:error];
}

- (NSArray *)rowsFromUTF8String:(const unsigned char *)string length:(NSUInteger)length
{
    return [self rowsFromUTF8String:string length:length error:nil];
}

- (NSArray *)rowsFromUTF8String:(const unsigned char *)string length:(NSUInteger)length error:(NSError **)error
{
    CFMutableArrayRef array = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);

    BOOL success = [self parseRowsFromUTF8String:string length:length block:^(NSArray *row, BOOL *stop) {
        CFArrayAppendValue(array, row);
    } error:error];

    if (CSV_UNLIKELY(!success))
    {
        CFRelease(array);
        return nil;
    }

    return [(NSArray *)array autorelease];
}

@end

@implementation CSVObjectParser

@synthesize objectClass = _objectClass;
@synthesize propertyNames = _propertyNames;

- (id)initWithDialect:(const CSVDialect *)dialect
{
    return [self initWithDialect:dialect objectClass:nil propertyNames:nil];
}

+ (id)parserWithDialect:(const CSVDialect *)dialect classClass:(Class)objectClass propertyNames:(NSArray *)propertyNames
{
    return [[[self alloc] initWithDialect:dialect objectClass:objectClass propertyNames:propertyNames] autorelease];
}

- (id)initWithDialect:(const CSVDialect *)dialect objectClass:(Class)objectClass propertyNames:(NSArray *)propertyNames
{
    if ((self = [super initWithDialect:dialect]))
    {
        self.objectClass = objectClass ? objectClass : [NSMutableDictionary class];
        self.propertyNames = propertyNames;
    }

    return self;
}

- (void)dealloc
{
    self.objectClass = nil;
    self.propertyNames = nil;
    [super dealloc];
}

#pragma mark Object Parsing

- (BOOL)parseObjectsFromData:(NSData *)data block:(void (^)(id object, BOOL *stop))block
{
    return [self parseObjectsFromData:data block:block error:nil];
}

- (BOOL)parseObjectsFromData:(NSData *)data block:(void (^)(id object, BOOL *stop))block error:(NSError **)error
{
    const unsigned char * const bytes = (const unsigned char *)[data bytes];
    return [self parseObjectsFromUTF8String:bytes length:[data length] block:block error:error];
}

- (BOOL)parseObjectsFromString:(NSString *)string block:(void (^)(id object, BOOL *stop))block
{
    return [self parseObjectsFromString:string block:block error:nil];
}

- (BOOL)parseObjectsFromString:(NSString *)string block:(void (^)(id object, BOOL *stop))block error:(NSError **)error
{
    return [self parseObjectsFromUTF8String:(const unsigned char *)[string UTF8String]
                                     length:[string lengthOfBytesUsingEncoding:NSUTF8StringEncoding]
                                      block:block
                                      error:error];
}

- (BOOL)parseObjectsFromUTF8String:(const unsigned char *)string
                            length:(NSUInteger)length
                             block:(void (^)(id object, BOOL *stop))block
{
    return [self parseObjectsFromUTF8String:string length:length block:block error:nil];
}

- (BOOL)parseObjectsFromUTF8String:(const unsigned char *)string
                            length:(NSUInteger)length
                             block:(void (^)(id object, BOOL *stop))block
                             error:(NSError **)error
{
    NSParameterAssert(string != NULL);
    NSParameterAssert(block != NULL);

    __block NSMutableArray *mutablePropertyNames = (_propertyNames) ? nil : [NSMutableArray array];
    __block id object = nil;

    context->fieldBlock = ^(NSUInteger index, CSVManagedBuffer *buffer, CSVFieldType type, BOOL *stop) {
        if (index != NSUIntegerMax)
        {
            id value = csv_parser_field_object(buffer, type);
            if (_propertyNames)
            {
                if (object == nil)
                {
                    object = [[_objectClass alloc] init];
                }

                id key = (id)CFArrayGetValueAtIndex((CFMutableArrayRef)_propertyNames, index);
                [object setValue:value forKey:key]; // TODO: Cache this selector?
            }
            else
            {
                CFArrayAppendValue((CFMutableArrayRef)mutablePropertyNames, value);
            }
            CFRelease(value);
        }
        else
        {
            if (_propertyNames)
            {
                block(object, stop);
                CFRelease(object);
                object = nil;
            }
            else
            {
                self.propertyNames = mutablePropertyNames;
            }
        }
    };

    if (CSV_UNLIKELY(csv_parser_parse_data(context, string, length) < 0))
    {
        if (error)
            *error = [context->error retain];
        return FALSE;
    }
    
    return TRUE;
}

#pragma mark Convenience Methods

- (NSArray *)objectsFromData:(NSData *)data
{
    return [self objectsFromData:data error:nil];
}

- (NSArray *)objectsFromData:(NSData *)data error:(NSError **)error
{
    const unsigned char * const bytes = (const unsigned char *)[data bytes];
    return [self objectsFromUTF8String:bytes length:[data length] error:error];
}

- (NSArray *)objectsFromString:(NSString *)string
{
    return [self objectsFromString:string error:nil];
}

- (NSArray *)objectsFromString:(NSString *)string error:(NSError **)error
{
    return [self objectsFromUTF8String:(const unsigned char *)[string UTF8String]
                                length:[string lengthOfBytesUsingEncoding:NSUTF8StringEncoding]
                                 error:error];
}

- (NSArray *)objectsFromUTF8String:(const unsigned char *)string length:(NSUInteger)length
{
    return [self objectsFromUTF8String:string length:length error:nil];
}

- (NSArray *)objectsFromUTF8String:(const unsigned char *)string length:(NSUInteger)length error:(NSError **)error
{
    CFMutableArrayRef array = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);

    BOOL success = [self parseObjectsFromUTF8String:string length:length block:^(id object, BOOL *stop) {
        CFArrayAppendValue(array, object);
    } error:error];

    if (CSV_UNLIKELY(!success))
    {
        CFRelease(array);
        return nil;
    }

    return [(NSArray *)array autorelease];    
}

@end
