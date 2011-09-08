//
//  CSVKitTests.m
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

#import "CSVKitTests.h"

#import "CSVKit.h"

@implementation CSVParserTests

#pragma mark Errors

- (void)testErrorDetails
{
    NSString *badString = [[NSString alloc] initWithBytes:"a,\0\0" length:4 encoding:NSASCIIStringEncoding];

    NSError *error = nil;
    [[CSVParser parser] rowsFromString:badString error:&error];

    STAssertEqualObjects([error domain], CSVErrorDomain, nil);

    NSDictionary *details = [error userInfo];
    STAssertEquals([[details objectForKey:CSVLineNumberKey] unsignedLongValue], 1UL, nil);
    STAssertEquals([[details objectForKey:CSVFieldNumberKey] longValue], 1L, nil);

    [badString release];
}

#pragma mark Fields

- (void)testFields
{
    NSMutableArray *array = [[NSMutableArray alloc] init];
    __block BOOL sawSentinel = NO;

    NSError *error = nil;
    [[CSVParser parser] parseFieldsFromString:@"a,b,c\n" block:^(id value, NSUInteger index, BOOL *stop) {
        if (index == NSUIntegerMax)
        {
            sawSentinel = YES;
        }
        else if (value)
        {
            [array addObject:value];
        }
    } error:&error];

    STAssertNil(error, nil);
    STAssertTrue(sawSentinel, nil);
    STAssertEquals(array.count, (NSUInteger)3, nil);

    [array release];
}

#pragma mark Rows

- (void)testRows
{
    NSArray *array = [[CSVParser parser] rowsFromString:@"one,two,three\n1,2,3"];
    STAssertEquals(array.count, (NSUInteger)2, nil);

    NSArray *row = [array objectAtIndex:0];
    STAssertEquals(row.count, (NSUInteger)3, nil);
    STAssertEqualObjects([row objectAtIndex:0], @"one", nil);
}

#pragma mark Objects

- (void)testObjects
{
    NSArray *array = [[CSVObjectParser parser] objectsFromString:@"one,two,three\n1,2,3"];
    STAssertEquals(array.count, (NSUInteger)1, nil);

    NSDictionary *dict = [array objectAtIndex:0];
    STAssertEquals(dict.count, (NSUInteger)3, nil);
    STAssertEqualObjects([dict objectForKey:@"one"], @"1", nil);
}

@end
