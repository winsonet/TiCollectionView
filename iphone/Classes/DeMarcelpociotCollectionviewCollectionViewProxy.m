/**
 * Appcelerator Titanium Mobile
 * Copyright (c) 2013 by Appcelerator, Inc. All Rights Reserved.
 * Licensed under the terms of the Apache Public License
 * Please see the LICENSE included with this distribution for details.
 */

#import "DeMarcelpociotCollectionviewCollectionViewProxy.h"
#import "DeMarcelpociotCollectionviewCollectionView.h"
#import "TiUtils.h"
#import "TiViewTemplate.h"

@interface DeMarcelpociotCollectionviewCollectionViewProxy ()
@property (nonatomic, readwrite) DeMarcelpociotCollectionviewCollectionView *listView;
@end

@implementation DeMarcelpociotCollectionviewCollectionViewProxy {
	NSMutableArray *_sections;
	NSMutableArray *_operationQueue;
	pthread_mutex_t _operationQueueMutex;
	pthread_rwlock_t _markerLock;
	NSIndexPath *marker;
}

- (id)init
{
    self = [super init];
    if (self) {
		_sections = [[NSMutableArray alloc] initWithCapacity:4];
		_operationQueue = [[NSMutableArray alloc] initWithCapacity:10];
		pthread_mutex_init(&_operationQueueMutex,NULL);
		pthread_rwlock_init(&_markerLock,NULL);
    }
    return self;
}

-(void)_initWithProperties:(NSDictionary *)properties
{
    [self initializeProperty:@"canScroll" defaultValue:NUMBOOL(YES)];
    [super _initWithProperties:properties];
}

- (void)dealloc
{
	[_operationQueue release];
	pthread_mutex_destroy(&_operationQueueMutex);
	pthread_rwlock_destroy(&_markerLock);
	[_sections release];
	RELEASE_TO_NIL(marker);
    [super dealloc];
}

- (DeMarcelpociotCollectionviewCollectionView *)listView
{
	return (DeMarcelpociotCollectionviewCollectionView *)self.view;
}

- (void)dispatchUpdateAction:(void(^)(UICollectionView *tableView))block
{
	if (view == nil) {
		block(nil);
		return;
	}
    
    if ([self.listView isSearchActive]) {
        block(nil);
        TiThreadPerformOnMainThread(^{
            [self.listView updateSearchResults:nil];
        }, NO);
        return;
    }
    
	BOOL triggerMainThread;
	pthread_mutex_lock(&_operationQueueMutex);
	triggerMainThread = [_operationQueue count] == 0;
	[_operationQueue addObject:Block_copy(block)];
    pthread_mutex_unlock(&_operationQueueMutex);
	if (triggerMainThread) {
		TiThreadPerformOnMainThread(^{
			[self processUpdateActions];
		}, NO);
	}
}

- (void)dispatchBlock:(void(^)(UICollectionView *tableView))block
{
	if (view == nil) {
		block(nil);
		return;
	}
	if ([NSThread isMainThread]) {
		return block(self.listView.collectionView);
	}
	TiThreadPerformOnMainThread(^{
		block(self.listView.collectionView);
	}, YES);
}

- (id)dispatchBlockWithResult:(id(^)(void))block
{
	if ([NSThread isMainThread]) {
		return block();
	}
	
	__block id result = nil;
	TiThreadPerformOnMainThread(^{
		result = [block() retain];
	}, YES);
	return [result autorelease];
}

- (void)processUpdateActions
{
	UICollectionView *tableView = self.listView.collectionView;
	BOOL removeHead = NO;
	while (YES) {
		void (^block)(UICollectionView *) = nil;
		pthread_mutex_lock(&_operationQueueMutex);
		if (removeHead) {
			[_operationQueue removeObjectAtIndex:0];
		}
		if ([_operationQueue count] > 0) {
			block = [_operationQueue objectAtIndex:0];
			removeHead = YES;
		}
		pthread_mutex_unlock(&_operationQueueMutex);
		if (block != nil) {
			block(tableView);
			Block_release(block);
		} else {
			[self.listView updateIndicesForVisibleRows];
			[self contentsWillChange];
			return;
		}
	}
}

- (DeMarcelpociotCollectionviewCollectionSectionProxy *)sectionForIndex:(NSUInteger)index
{
	if (index < [_sections count]) {
		return [_sections objectAtIndex:index];
	}
	return nil;
}

- (void) deleteSectionAtIndex:(NSUInteger)index
{
    if ([_sections count] <= index) {
        DebugLog(@"[WARN] ListViewProxy: Delete section index is out of range");
        return;
    }
    DeMarcelpociotCollectionviewCollectionSectionProxy *section = [_sections objectAtIndex:index];
    [_sections removeObjectAtIndex:index];
    section.delegate = nil;
    [_sections enumerateObjectsUsingBlock:^(DeMarcelpociotCollectionviewCollectionSectionProxy *section, NSUInteger idx, BOOL *stop) {
        section.sectionIndex = idx;
    }];
    [self forgetProxy:section];
}

- (NSArray *)keySequence
{
	static dispatch_once_t onceToken;
	static NSArray *keySequence = nil;
	dispatch_once(&onceToken, ^{
		keySequence = [[NSArray alloc] initWithObjects:@"style", @"templates", @"defaultItemTemplate", @"sections", @"backgroundColor",nil];
	});
	return keySequence;
}

- (void)viewDidAttach
{
	[self.listView collectionView];
}

- (void)willShow
{
	[super willShow];
}

#pragma mark - Public API

- (void)setTemplates:(id)args
{
	ENSURE_TYPE_OR_NIL(args,NSDictionary);
	NSMutableDictionary *templates = [[NSMutableDictionary alloc] initWithCapacity:[args count]];
	[(NSDictionary *)args enumerateKeysAndObjectsUsingBlock:^(NSString *key, id obj, BOOL *stop) {
		TiViewTemplate *template = [TiViewTemplate templateFromViewTemplate:obj];
		if (template != nil) {
			[templates setObject:template forKey:key];
		}
	}];
	TiThreadPerformOnMainThread(^{
		[self.listView setDictTemplates_:templates];
	}, NO);
	[templates release];
}

- (NSArray *)sections
{
	return [self dispatchBlockWithResult:^() {
		return [[_sections copy] autorelease];
	}];
}

- (NSNumber *)sectionCount
{
	return [self dispatchBlockWithResult:^() {
		return [NSNumber numberWithUnsignedInteger:[_sections count]];
	}];
}

- (void)setSections:(id)args
{
	ENSURE_TYPE_OR_NIL(args,NSArray);
	NSMutableArray *insertedSections = [args mutableCopy];
	[insertedSections enumerateObjectsUsingBlock:^(DeMarcelpociotCollectionviewCollectionSectionProxy *section, NSUInteger idx, BOOL *stop) {
		ENSURE_TYPE(section, DeMarcelpociotCollectionviewCollectionSectionProxy);
		[self rememberProxy:section];
	}];
	[self dispatchBlock:^(UICollectionView *tableView) {
		[_sections enumerateObjectsUsingBlock:^(DeMarcelpociotCollectionviewCollectionSectionProxy *section, NSUInteger idx, BOOL *stop) {
			section.delegate = nil;
			if (![insertedSections containsObject:section]) {
				[self forgetProxy:section];
			}
		}];
		[_sections release];
		_sections = [insertedSections retain];
		[_sections enumerateObjectsUsingBlock:^(DeMarcelpociotCollectionviewCollectionSectionProxy *section, NSUInteger idx, BOOL *stop) {
			section.delegate = self;
			section.sectionIndex = idx;
		}];
		[tableView reloadData];
		[self contentsWillChange];
	}];
	[insertedSections release];
}

- (void)appendSection:(id)args
{
	ENSURE_ARG_COUNT(args, 1);
	id arg = [args objectAtIndex:0];
	NSArray *appendedSections = [arg isKindOfClass:[NSArray class]] ? arg : [NSArray arrayWithObject:arg];
	if ([appendedSections count] == 0) {
		return;
	}
	NSDictionary *properties = [args count] > 1 ? [args objectAtIndex:1] : nil;
	[appendedSections enumerateObjectsUsingBlock:^(DeMarcelpociotCollectionviewCollectionSectionProxy *section, NSUInteger idx, BOOL *stop) {
		ENSURE_TYPE(section, DeMarcelpociotCollectionviewCollectionSectionProxy);
		[self rememberProxy:section];
	}];
	[self dispatchUpdateAction:^(UICollectionView *tableView) {
		NSMutableIndexSet *indexSet = [[NSMutableIndexSet alloc] init];
		[appendedSections enumerateObjectsUsingBlock:^(DeMarcelpociotCollectionviewCollectionSectionProxy *section, NSUInteger idx, BOOL *stop) {
			if (![_sections containsObject:section]) {
				NSUInteger insertIndex = [_sections count];
				[_sections addObject:section];
				section.delegate = self;
				section.sectionIndex = insertIndex;
				[indexSet addIndex:insertIndex];
			} else {
				DebugLog(@"[WARN] ListView: Attempt to append exising section");
			}
		}];
		if ([indexSet count] > 0) {
			[tableView insertSections:indexSet];
		}
		[indexSet release];
	}];
}

- (void)deleteSectionAt:(id)args
{
	ENSURE_ARG_COUNT(args, 1);
	NSUInteger deleteIndex = [TiUtils intValue:[args objectAtIndex:0]];
	NSDictionary *properties = [args count] > 1 ? [args objectAtIndex:1] : nil;
	[self dispatchUpdateAction:^(UICollectionView *tableView) {
		if ([_sections count] <= deleteIndex) {
			DebugLog(@"[WARN] ListView: Delete section index is out of range");
			return;
		}
		DeMarcelpociotCollectionviewCollectionSectionProxy *section = [_sections objectAtIndex:deleteIndex];
		[_sections removeObjectAtIndex:deleteIndex];
		section.delegate = nil;
		[_sections enumerateObjectsUsingBlock:^(DeMarcelpociotCollectionviewCollectionSectionProxy *section, NSUInteger idx, BOOL *stop) {
			section.sectionIndex = idx;
		}];
		[tableView deleteSections:[NSIndexSet indexSetWithIndex:deleteIndex]];
		[self forgetProxy:section];
	}];
}

- (void)insertSectionAt:(id)args
{
	ENSURE_ARG_COUNT(args, 2);
	NSUInteger insertIndex = [TiUtils intValue:[args objectAtIndex:0]];
	id arg = [args objectAtIndex:1];
	NSArray *insertSections = [arg isKindOfClass:[NSArray class]] ? arg : [NSArray arrayWithObject:arg];
	if ([insertSections count] == 0) {
		return;
	}
	NSDictionary *properties = [args count] > 2 ? [args objectAtIndex:2] : nil;
	[insertSections enumerateObjectsUsingBlock:^(DeMarcelpociotCollectionviewCollectionSectionProxy *section, NSUInteger idx, BOOL *stop) {
		ENSURE_TYPE(section, DeMarcelpociotCollectionviewCollectionSectionProxy);
		[self rememberProxy:section];
	}];
	[self dispatchUpdateAction:^(UICollectionView *tableView) {
		if ([_sections count] < insertIndex) {
			DebugLog(@"[WARN] ListView: Insert section index is out of range");
			[insertSections enumerateObjectsUsingBlock:^(DeMarcelpociotCollectionviewCollectionSectionProxy *section, NSUInteger idx, BOOL *stop) {
				[self forgetProxy:section];
			}];
			return;
		}
		NSMutableIndexSet *indexSet = [[NSMutableIndexSet alloc] init];
		__block NSUInteger index = insertIndex;
		[insertSections enumerateObjectsUsingBlock:^(DeMarcelpociotCollectionviewCollectionSectionProxy *section, NSUInteger idx, BOOL *stop) {
			if (![_sections containsObject:section]) {
				[_sections insertObject:section atIndex:index];
				section.delegate = self;
				[indexSet addIndex:index];
				++index;
			} else {
				DebugLog(@"[WARN] ListView: Attempt to insert exising section");
			}
		}];
		[_sections enumerateObjectsUsingBlock:^(DeMarcelpociotCollectionviewCollectionSectionProxy *section, NSUInteger idx, BOOL *stop) {
			section.sectionIndex = idx;
		}];
		[tableView insertSections:indexSet];
		[indexSet release];
	}];
}

- (void)replaceSectionAt:(id)args
{
	ENSURE_ARG_COUNT(args, 2);
	NSUInteger replaceIndex = [TiUtils intValue:[args objectAtIndex:0]];
	DeMarcelpociotCollectionviewCollectionSectionProxy *section = [args objectAtIndex:1];
	ENSURE_TYPE_OR_NIL(section, DeMarcelpociotCollectionviewCollectionSectionProxy);
	NSDictionary *properties = [args count] > 2 ? [args objectAtIndex:2] : nil;
	
	[self rememberProxy:section];
	[self dispatchUpdateAction:^(UICollectionView *tableView) {
		if ([_sections containsObject:section]) {
			DebugLog(@"[WARN] ListView: Attempt to insert exising section");
			return;
		}
		if ([_sections count] <= replaceIndex) {
			DebugLog(@"[WARN] ListView: Replace section index is out of range");
			[self forgetProxy:section];
			return;
		}
		DeMarcelpociotCollectionviewCollectionSectionProxy *prevSection = [_sections objectAtIndex:replaceIndex];
		prevSection.delegate = nil;
		[_sections replaceObjectAtIndex:replaceIndex withObject:section];
		section.delegate = self;
		section.sectionIndex = replaceIndex;
		NSIndexSet *indexSet = [NSIndexSet indexSetWithIndex:replaceIndex];
		[tableView deleteSections:indexSet];
		[tableView insertSections:indexSet];
		[self forgetProxy:prevSection];
	}];
}

- (void)scrollToItem:(id)args
{
    if (view != nil) {
        ENSURE_ARG_COUNT(args, 2);
        NSUInteger sectionIndex = [TiUtils intValue:[args objectAtIndex:0]];
        NSUInteger itemIndex = [TiUtils intValue:[args objectAtIndex:1]];
        NSDictionary *properties = [args count] > 2 ? [args objectAtIndex:2] : nil;
        UICollectionViewScrollPosition scrollPosition = [TiUtils intValue:@"position" properties:properties def:UICollectionViewScrollPositionNone];
        BOOL animated = [TiUtils boolValue:@"animated" properties:properties def:YES];
        TiThreadPerformOnMainThread(^{
            if ([_sections count] <= sectionIndex) {
                DebugLog(@"[WARN] ListView: Scroll to section index is out of range");
                return;
            }
            DeMarcelpociotCollectionviewCollectionSectionProxy *section = [_sections objectAtIndex:sectionIndex];
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:MIN(itemIndex, section.itemCount) inSection:sectionIndex];
            [self.listView.collectionView scrollToItemAtIndexPath:indexPath atScrollPosition:scrollPosition animated:animated];
        }, NO);
    }
}

- (void)selectItem:(id)args
{
    if (view != nil) {
        ENSURE_ARG_COUNT(args, 2);
        NSUInteger sectionIndex = [TiUtils intValue:[args objectAtIndex:0]];
        NSUInteger itemIndex = [TiUtils intValue:[args objectAtIndex:1]];
        TiThreadPerformOnMainThread(^{
            if ([_sections count] <= sectionIndex) {
                DebugLog(@"[WARN] ListView: Select section index is out of range");
                return;
            }
            DeMarcelpociotCollectionviewCollectionSectionProxy *section = [_sections objectAtIndex:sectionIndex];
            if (section.itemCount <= itemIndex) {
                DebugLog(@"[WARN] ListView: Select item index is out of range");
                return;
            }
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:itemIndex inSection:sectionIndex];
            [self.listView.collectionView selectItemAtIndexPath:indexPath animated:YES scrollPosition:UICollectionViewScrollPositionNone];
            [self.listView.collectionView scrollToItemAtIndexPath:indexPath atScrollPosition:UICollectionViewScrollPositionNone animated:YES];
        }, NO);
    }
}

- (void)deselectItem:(id)args
{
    if (view != nil) {
        ENSURE_ARG_COUNT(args, 2);
        NSUInteger sectionIndex = [TiUtils intValue:[args objectAtIndex:0]];
        NSUInteger itemIndex = [TiUtils intValue:[args objectAtIndex:1]];
        TiThreadPerformOnMainThread(^{
            if ([_sections count] <= sectionIndex) {
                DebugLog(@"[WARN] ListView: Select section index is out of range");
                return;
            }
            DeMarcelpociotCollectionviewCollectionSectionProxy *section = [_sections objectAtIndex:sectionIndex];
            if (section.itemCount <= itemIndex) {
                DebugLog(@"[WARN] ListView: Select item index is out of range");
                return;
            }
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:itemIndex inSection:sectionIndex];
            [self.listView.collectionView deselectItemAtIndexPath:indexPath animated:YES];
        }, NO);
    }
}

-(void)setContentInsets:(id)args
{
    id arg1;
    id arg2;
    if ([args isKindOfClass:[NSDictionary class]]) {
        arg1 = args;
        arg2 = nil;
    }
    else {
        arg1 = [args objectAtIndex:0];
        arg2 = [args count] > 1 ? [args objectAtIndex:1] : nil;
    }
    TiThreadPerformOnMainThread(^{
        [self.listView setContentInsets_:arg1 withObject:arg2];
    }, NO);
}

#pragma mark - Marker Support
- (void)setMarker:(id)args;
{
    ENSURE_SINGLE_ARG(args, NSDictionary);
    pthread_rwlock_wrlock(&_markerLock);
    int section = [TiUtils intValue:[args objectForKey:@"sectionIndex"] def:NSIntegerMax];
    int row = [TiUtils intValue:[args objectForKey:@"itemIndex"] def:NSIntegerMax];
    RELEASE_TO_NIL(marker);
    marker = [[NSIndexPath indexPathForRow:row inSection:section] retain];
    pthread_rwlock_unlock(&_markerLock);
}

-(void)willDisplayCell:(NSIndexPath*)indexPath
{
    if ((marker != nil) && [self _hasListeners:@"marker"]) {
        //Never block the UI thread
        int result = pthread_rwlock_tryrdlock(&_markerLock);
        if (result != 0) {
            return;
        }
        if ( (indexPath.section > marker.section) || ( (marker.section == indexPath.section) && (indexPath.row >= marker.row) ) ){
            [self fireEvent:@"marker" withObject:nil withSource:self propagate:NO reportSuccess:NO errorCode:0 message:nil];
            RELEASE_TO_NIL(marker);
        }
        pthread_rwlock_unlock(&_markerLock);
    }
}

DEFINE_DEF_BOOL_PROP(willScrollOnStatusTap,YES);
USE_VIEW_FOR_CONTENT_HEIGHT
USE_VIEW_FOR_CONTENT_WIDTH

@end