#import "WPAnalyticsTrackerMixpanel.h"
#import <Mixpanel/Mixpanel.h>
#import "WPAnalyticsTrackerMixpanelInstructionsForStat.h"
#import "WordPressComApiCredentials.h"
#import "AccountService.h"
#import "WPAccount.h"
#import "ContextManager.h"
#import "Blog.h"
#import "BlogService.h"
#import "WPAnalyticsTrackerMixpanel.h"
#import "AccountServiceRemoteREST.h"

@implementation WPAnalyticsTrackerMixpanel

NSString *const EmailAddressRetrievedKey = @"email_address_retrieved";

- (instancetype)init
{
    self = [super init];
    if (self) {
        _aggregatedStatProperties = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)beginSession
{
    [Mixpanel sharedInstanceWithToken:[WordPressComApiCredentials mixpanelAPIToken]];
    [self refreshMetadata];
}

- (void)track:(WPAnalyticsStat)stat
{
    [self track:stat withProperties:nil];
}

- (void)track:(WPAnalyticsStat)stat withProperties:(NSDictionary *)properties
{
    WPAnalyticsTrackerMixpanelInstructionsForStat *instructions = [self instructionsForStat:stat];
    if (instructions == nil) {
        DDLogInfo(@"No instructions, do nothing");
        return;
    }

    [self trackMixpanelDataForInstructions:instructions andProperties:properties];
}

- (void)endSession
{
    [_aggregatedStatProperties removeAllObjects];
}

- (void)refreshMetadata
{
    NSManagedObjectContext *context = [[ContextManager sharedInstance] mainContext];
    AccountService *accountService = [[AccountService alloc] initWithManagedObjectContext:context];
    WPAccount *account = [accountService defaultWordPressComAccount];
    BlogService *blogService = [[BlogService alloc] initWithManagedObjectContext:[[ContextManager sharedInstance] mainContext]];

    BOOL dotcom_user = NO;
    BOOL jetpack_user = NO;
    if (account != nil) {
        dotcom_user = YES;
        if ([[account jetpackBlogs] count] > 0) {
            jetpack_user = YES;
        }
    }

    NSMutableDictionary *superProperties = [[NSMutableDictionary alloc] initWithDictionary:[Mixpanel sharedInstance].currentSuperProperties];
    superProperties[@"platform"] = @"iOS";
    superProperties[@"dotcom_user"] = @(dotcom_user);
    superProperties[@"jetpack_user"] = @(jetpack_user);
    superProperties[@"number_of_blogs"] = @([blogService blogCountForAllAccounts]);
    superProperties[@"accessibility_voice_over_enabled"] = @(UIAccessibilityIsVoiceOverRunning());
    [[Mixpanel sharedInstance] registerSuperProperties:superProperties];

    NSString *username = account.username;
    if (account && [username length] > 0) {
        [[Mixpanel sharedInstance] identify:username];
        [[Mixpanel sharedInstance].people set:@{ @"$username": username, @"$first_name" : username }];
    }

    [self retrieveAndRegisterEmailAddressIfApplicable];
}

- (void)retrieveAndRegisterEmailAddressIfApplicable
{
    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    if ([userDefaults boolForKey:EmailAddressRetrievedKey]) {
        return;
    }

    DDLogInfo(@"Retrieving /me endpoint");

    NSManagedObjectContext *context = [[ContextManager sharedInstance] mainContext];
    AccountService *accountService = [[AccountService alloc] initWithManagedObjectContext:context];

    WPAccount *defaultAccount = [accountService defaultWordPressComAccount];
    if (defaultAccount == nil) {
        return;
    }

    AccountServiceRemoteREST *remote = [[AccountServiceRemoteREST alloc] initWithApi:defaultAccount.restApi];
    [remote getDetailsWithSuccess:^(NSDictionary *userDetails) {
        if ([[userDetails stringForKey:@"email"] length] > 0) {
            [[Mixpanel sharedInstance].people set:@"$email" to:[userDetails stringForKey:@"email"]];
            [userDefaults setBool:YES forKey:EmailAddressRetrievedKey];
            [userDefaults synchronize];
        }
    } failure:^(NSError *error) {
        DDLogError(@"Failed to retrieve /me endpoint");
    }];
}

+ (void)resetEmailRetrievalCheck
{
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:EmailAddressRetrievedKey];
}

#pragma mark - Private Methods

- (NSString *)convertWPStatToString:(WPAnalyticsStat)stat
{
    return [NSString stringWithFormat:@"%d", stat];
}

- (BOOL)connectedToWordPressDotCom
{
    NSManagedObjectContext *context = [[ContextManager sharedInstance] mainContext];
    AccountService *accountService = [[AccountService alloc] initWithManagedObjectContext:context];
    WPAccount *defaultAccount = [accountService defaultWordPressComAccount];

    return [[defaultAccount restApi] hasCredentials];
}

- (void)trackMixpanelDataForInstructions:(WPAnalyticsTrackerMixpanelInstructionsForStat *)instructions andProperties:(NSDictionary *)properties
{
    if (instructions.disableTrackingForSelfHosted) {
        if (![self connectedToWordPressDotCom]) {
            return;
        }
    }

    if ([instructions.mixpanelEventName length] > 0) {
        NSDictionary *aggregatedPropertiesForEvent = [self propertiesForStat:instructions.stat];
        if (aggregatedPropertiesForEvent != nil) {
            NSMutableDictionary *combinedProperties = [[NSMutableDictionary alloc] init];
            [combinedProperties addEntriesFromDictionary:aggregatedPropertiesForEvent];
            [combinedProperties addEntriesFromDictionary:properties];
            [[Mixpanel sharedInstance] track:instructions.mixpanelEventName properties:combinedProperties];
        } else {
            [[Mixpanel sharedInstance] track:instructions.mixpanelEventName properties:properties];
        }
    }

    if ([instructions.superPropertyToIncrement length] > 0) {
        [self incrementSuperProperty:instructions.superPropertyToIncrement];
    }

    if ([instructions.peoplePropertyToIncrement length] > 0) {
        [self incrementPeopleProperty:instructions.peoplePropertyToIncrement];
    }

    if ([instructions.propertyToIncrement length] > 0) {
        [self incrementProperty:instructions.propertyToIncrement forStat:instructions.statToAttachProperty];
    }

    [instructions.superPropertiesToFlag enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        [self flagSuperProperty:obj];
    }];

    [instructions.peoplePropertiesToAssign enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        [self setValue:obj forPeopleProperty:key];
    }];
}

- (void)incrementPeopleProperty:(NSString *)property
{
    [[Mixpanel sharedInstance].people increment:property by:@(1)];
}

- (void)incrementSuperProperty:(NSString *)property
{
    NSMutableDictionary *superProperties = [[NSMutableDictionary alloc] initWithDictionary:[Mixpanel sharedInstance].currentSuperProperties];
    NSUInteger propertyValue = [superProperties[property] integerValue];
    superProperties[property] = @(++propertyValue);
    [[Mixpanel sharedInstance] registerSuperProperties:superProperties];
}

- (void)flagSuperProperty:(NSString *)property
{
    NSMutableDictionary *superProperties = [[NSMutableDictionary alloc] initWithDictionary:[Mixpanel sharedInstance].currentSuperProperties];
    superProperties[property] = @(YES);
    [[Mixpanel sharedInstance] registerSuperProperties:superProperties];
}

- (void)setValue:(id)value forPeopleProperty:(NSString *)property
{
    [[Mixpanel sharedInstance].people set:@{ property : value } ];
}

- (WPAnalyticsTrackerMixpanelInstructionsForStat *)instructionsForStat:(WPAnalyticsStat )stat
{
    WPAnalyticsTrackerMixpanelInstructionsForStat *instructions;

    switch (stat) {
        case WPAnalyticsStatApplicationOpened:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Application Opened"];
            [instructions setPeoplePropertyToIncrement:@"Application Opened"];
            [self incrementSessionCount];
            break;
        case WPAnalyticsStatApplicationClosed:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Application Closed"];
            break;
        case WPAnalyticsStatThemesAccessedThemeBrowser:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Themes - Accessed Theme Browser"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_accessed_theme_browser"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_accessed_theme_browser"];
            break;
        case WPAnalyticsStatThemesChangedTheme:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Themes - Changed Theme"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_changed_theme"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_changed_theme"];
            break;
        case WPAnalyticsStatReaderAccessed:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Reader - Accessed"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_accessed_reader"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_accessed_reader"];
            break;
        case WPAnalyticsStatReaderOpenedArticle:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Reader - Opened Article"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_opened_article"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_opened_reader_article"];
            break;
        case WPAnalyticsStatReaderLikedArticle:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Reader - Liked Article"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_liked_article"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_liked_reader_article"];
            break;
        case WPAnalyticsStatReaderRebloggedArticle:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Reader - Reblogged Article"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_reblogged_article"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_reblogged_article"];
            break;
        case WPAnalyticsStatReaderInfiniteScroll:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Reader - Infinite Scroll"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_reader_performed_infinite_scroll"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_performed_reader_infinite_scroll"];
            break;
        case WPAnalyticsStatReaderFollowedReaderTag:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Reader - Followed Reader Tag"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_followed_reader_tag"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_followed_reader_tag"];
            break;
        case WPAnalyticsStatReaderUnfollowedReaderTag:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Reader - Unfollowed Reader Tag"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_unfollowed_reader_tag"];
            break;
        case WPAnalyticsStatReaderFollowedSite:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Reader - Followed Site"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_followed_site"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_followed_site"];
            break;
        case WPAnalyticsStatReaderLoadedTag:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Reader - Loaded Tag"];
            break;
        case WPAnalyticsStatReaderLoadedFreshlyPressed:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Reader - Loaded Freshly Pressed"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_loaded_freshly_pressed"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_loaded_freshly_pressed"];
            break;
        case WPAnalyticsStatReaderCommentedOnArticle:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Reader - Commented on Article"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_commented_on_reader_article"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_commented_on_article"];
            break;
        case WPAnalyticsStatStatsAccessed:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Stats - Accessed"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_accessed_stats"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_accessed_stats"];
            break;
        case WPAnalyticsStatStatsTappedBarChart:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Stats - Tapped Bar Chart"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_tapped_stats_bar_chart"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_tapped_stats_bar_chart"];
            break;
        case WPAnalyticsStatStatsOpenedWebVersion:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Stats - Opened Web Version"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_accessed_web_version_of_stats"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_accessed_web_version_of_stats"];
            break;
        case WPAnalyticsStatStatsScrolledToBottom:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Stats - Scrolled to Bottom"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_scrolled_to_bottom_of_stats"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_scrolled_to_bottom_of_stats"];
            break;
        case WPAnalyticsStatEditorUploadMediaFailed:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Editor - Upload Media Failed"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_editor_upload_media_failed"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_editor_upload_media_failed"];
            break;
        case WPAnalyticsStatEditorUploadMediaRetried:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Editor - Retried Uploading Media"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_editor_retried_uploading_media"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_editor_retried_uploading_media"];
            break;
        case WPAnalyticsStatEditorCreatedPost:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Editor - Created Post"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_editor_created_post"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_created_post_in_editor"];
            break;
        case WPAnalyticsStatEditorAddedPhotoViaLocalLibrary:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Editor - Added Photo via Local Library"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_added_photo_via_local_library"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_added_photo_via_local_library_to_post"];
            break;
        case WPAnalyticsStatEditorAddedPhotoViaWPMediaLibrary:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Editor - Added Photo via WP Media Library"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_added_photo_via_wp_media_library"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_added_photo_via_wp_media_library_to_post"];
            break;
        case WPAnalyticsStatEditorPublishedPost:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Editor - Published Post"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_editor_published_post"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_published_post"];
            break;
        case WPAnalyticsStatEditorUpdatedPost:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Editor - Updated Post"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_editor_updated_post"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_updated_post"];
            break;
        case WPAnalyticsStatEditorScheduledPost:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Editor - Scheduled Post"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_editor_scheduled_post"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_scheduled_post"];
            break;
        case WPAnalyticsStatEditorTappedImage:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Editor - Tapped Image Button"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_editor_tapped_image"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_tapped_image_in_editor"];
            break;
        case WPAnalyticsStatEditorTappedBold:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Editor - Tapped Bold Button"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_editor_tapped_bold"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_tapped_bold_in_editor"];
            break;
        case WPAnalyticsStatEditorTappedItalic:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Editor - Tapped Italics Button"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_editor_tapped_italic"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_tapped_italic_in_editor"];
            break;
        case WPAnalyticsStatEditorTappedStrikethrough:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Editor - Tapped Strikethrough Button"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_editor_tapped_strikethrough"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_tapped_strikethrough_in_editor"];
            break;
        case WPAnalyticsStatEditorTappedUnderline:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Editor - Tapped Underline Button"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_editor_tapped_underline"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_tapped_underline_in_editor"];
            break;
        case WPAnalyticsStatEditorTappedBlockquote:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Editor - Tapped Blockquote Button"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_editor_tapped_blockquote"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_tapped_blockquote_in_editor"];
            break;
        case WPAnalyticsStatEditorTappedUnorderedList:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Editor - Tapped Unordered List Button"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_editor_tapped_unordered_list"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_tapped_unordered_list_in_editor"];
            break;
        case WPAnalyticsStatEditorTappedOrderedList:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Editor - Tapped Ordered List Button"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_editor_tapped_ordered_list"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_tapped_ordered_list_in_editor"];
            break;
        case WPAnalyticsStatEditorTappedLink:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Editor - Tapped Link Button"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_editor_tapped_link"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_tapped_link_in_editor"];
            break;
        case WPAnalyticsStatEditorTappedUnlink:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Editor - Tapped Unlink Button"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_editor_tapped_unlink"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_tapped_unlink_in_editor"];
            break;
        case WPAnalyticsStatEditorTappedMore:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Editor - Tapped More Button"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_editor_tapped_more"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_tapped_more_in_editor"];
            break;
        case WPAnalyticsStatEditorTappedHTML:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Editor - Tapped HTML Button"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_editor_tapped_html"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_tapped_html_in_editor"];
            break;
        case WPAnalyticsStatEditorClosed:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Editor - Closed"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_editor_closed"];
            break;
        case WPAnalyticsStatEditorDiscardedChanges:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Editor - Discarded Changes"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_editor_discarded_changes"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_discarded_changes"];
            break;
        case WPAnalyticsStatEditorSavedDraft:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Editor - Saved Draft"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_editor_saved_draft"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_saved_draft"];
            break;
        case WPAnalyticsStatNotificationsAccessed:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Notifications - Accessed"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_accessed_notifications"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_accessed_notifications"];
            break;
        case WPAnalyticsStatNotificationsOpenedNotificationDetails:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Notifications - Opened Notification Details"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_opened_notification_details"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_opened_notification_details"];
            break;
        case WPAnalyticsStatOpenedPosts:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Site Menu - Opened Posts"];
            break;
        case WPAnalyticsStatOpenedPages:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Site Menu - Opened Pages"];
            break;
        case WPAnalyticsStatOpenedComments:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Site Menu - Opened Comments"];
            break;
        case WPAnalyticsStatOpenedViewSite:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Site Menu - Opened View Site"];
            break;
        case WPAnalyticsStatOpenedViewAdmin:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Site Menu - Opened View Admin"];
            break;
        case WPAnalyticsStatOpenedMediaLibrary:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Site Menu - Opened Media Library"];
            break;
        case WPAnalyticsStatOpenedSettings:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Site Menu - Opened Settings"];
            break;
        case WPAnalyticsStatCreatedAccount:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Created Account"];
            [instructions setCurrentDateForPeopleProperty:@"$created"];
            [instructions addSuperPropertyToFlag:@"created_account_on_mobile"];
            break;
        case WPAnalyticsStatEditorEnabledNewVersion:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Editor - Enabled New Version"];
            [instructions addSuperPropertyToFlag:@"enabled_new_editor"];
            break;
        case WPAnalyticsStatSharedItemViaEmail:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsWithSuperPropertyAndPeoplePropertyIncrementor:@"number_of_items_shared_via_email"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_shared_item_via_email"];
            break;
        case WPAnalyticsStatSharedItemViaSMS:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsWithSuperPropertyAndPeoplePropertyIncrementor:@"number_of_items_shared_via_sms"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_shared_item_via_sms"];
            break;
        case WPAnalyticsStatSharedItemViaFacebook:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsWithSuperPropertyAndPeoplePropertyIncrementor:@"number_of_items_shared_via_facebook"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_shared_item_via_facebook"];
            break;
        case WPAnalyticsStatSharedItemViaTwitter:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsWithSuperPropertyAndPeoplePropertyIncrementor:@"number_of_items_shared_via_twitter"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_shared_item_via_twitter"];
            break;
        case WPAnalyticsStatSharedItemViaWeibo:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsWithSuperPropertyAndPeoplePropertyIncrementor:@"number_of_items_shared_via_weibo"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_shared_item_via_weibo"];
            break;
        case WPAnalyticsStatSentItemToInstapaper:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsWithSuperPropertyAndPeoplePropertyIncrementor:@"number_of_items_sent_to_instapaper"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_sent_item_to_instapaper"];
            break;
        case WPAnalyticsStatSentItemToPocket:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsWithSuperPropertyAndPeoplePropertyIncrementor:@"number_of_items_sent_to_pocket"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_sent_item_to_pocket"];
            break;
        case WPAnalyticsStatSentItemToGooglePlus:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsWithSuperPropertyAndPeoplePropertyIncrementor:@"number_of_items_sent_to_google_plus"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_sent_item_to_google_plus"];
            break;
        case WPAnalyticsStatSentItemToWordPress:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsWithSuperPropertyAndPeoplePropertyIncrementor:@"number_of_items_sent_to_wordpress"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_sent_item_to_wordpress"];
            break;
        case WPAnalyticsStatSharedItem:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsWithSuperPropertyAndPeoplePropertyIncrementor:@"number_of_items_shared"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_shared_article"];
            break;
        case WPAnalyticsStatNotificationApproved:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsWithSuperPropertyAndPeoplePropertyIncrementor:@"number_of_notifications_approved"];
            break;
        case WPAnalyticsStatNotificationUnapproved:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsWithSuperPropertyAndPeoplePropertyIncrementor:@"number_of_notifications_unapproved"];
            break;
        case WPAnalyticsStatNotificationFollowAction:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Notifications - Followed User"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_followed_user_from_notification"];
            break;
        case WPAnalyticsStatNotificationUnfollowAction:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Notifications - Unfollowed User"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_times_unfollowed_user_from_notification"];
            break;
        case WPAnalyticsStatNotificationLiked:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Notifications - Liked Comment"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_comment_likes_from_notification"];
            break;
        case WPAnalyticsStatNotificationUnliked:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Notifications - Unliked Comment"];
            [instructions setSuperPropertyAndPeoplePropertyToIncrement:@"number_of_comment_unlikes_from_notification"];
            break;
        case WPAnalyticsStatNotificationRepliedTo:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsWithSuperPropertyAndPeoplePropertyIncrementor:@"number_of_notifications_replied_to"];
            break;
        case WPAnalyticsStatNotificationTrashed:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsWithSuperPropertyAndPeoplePropertyIncrementor:@"number_of_notifications_trashed"];
            break;
        case WPAnalyticsStatNotificationFlaggedAsSpam:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsWithSuperPropertyAndPeoplePropertyIncrementor:@"number_of_notifications_flagged_as_spam"];
            break;
        case WPAnalyticsStatNotificationsMissingSyncWarning:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsWithSuperPropertyAndPeoplePropertyIncrementor:@"notifications_sync_timeout"];
            break;
        case WPAnalyticsStatPublishedPostWithPhoto:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsWithSuperPropertyAndPeoplePropertyIncrementor:@"number_of_posts_published_with_photos"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_published_post_with_photo"];
            break;
        case WPAnalyticsStatPublishedPostWithVideo:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsWithSuperPropertyAndPeoplePropertyIncrementor:@"number_of_posts_published_with_videos"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_published_post_with_video"];
            break;
        case WPAnalyticsStatPublishedPostWithCategories:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsWithSuperPropertyAndPeoplePropertyIncrementor:@"number_of_posts_published_with_categories"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_published_post_with_category"];
            break;
        case WPAnalyticsStatPublishedPostWithTags:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsWithSuperPropertyAndPeoplePropertyIncrementor:@"number_of_posts_published_with_tags"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_published_post_with_tags"];
            break;
        case WPAnalyticsStatAddedSelfHostedSite:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Added Self Hosted Site"];
            [instructions setCurrentDateForPeopleProperty:@"last_time_added_self_hosted_site"];
            break;
        case WPAnalyticsStatAddedSelfHostedSiteButJetpackNotConnectedToWPCom:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Added Self Hosted Site Not Connected to Wordpress.com"];
            break;
        case WPAnalyticsStatSkippedConnectingToJetpack:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Skipped Connecting to Jetpack"];
            break;
        case WPAnalyticsStatSignedInToJetpack:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Signed into Jetpack"];
            [instructions addSuperPropertyToFlag:@"jetpack_user"];
            [instructions addSuperPropertyToFlag:@"dotcom_user"];
            break;
        case WPAnalyticsStatSignedIn:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Signed In"];
            break;
        case WPAnalyticsStatSelectedLearnMoreInConnectToJetpackScreen:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Selected Learn More in Connect to Jetpack Screen"];
            break;
        case WPAnalyticsStatPerformedJetpackSignInFromStatsScreen:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Signed into Jetpack from Stats Screen"];
            break;
        case WPAnalyticsStatSelectedInstallJetpack:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Selected Install Jetpack"];
            break;
        case WPAnalyticsStatSupportOpenedHelpshiftScreen:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Support - Opened Helpshift Screen"];
            [instructions addSuperPropertyToFlag:@"opened_helpshift_screen"];
            break;
        case WPAnalyticsStatSupportReceivedResponseFromSupport:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsWithSuperPropertyFlagger:@"received_response_from_support"];
            break;
        case WPAnalyticsStatLowMemoryWarning:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Received Low Memory Warning"];
            break;
        case WPAnalyticsStatAppReviewsSawPrompt:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Reviews - Saw App Review Prompt"];
            [instructions addSuperPropertyToFlag:@"saw_app_review_prompt"];
            [instructions.peoplePropertiesToAssign setValue:@(YES) forKey:@"saw_app_review_prompt"];
            break;
        case WPAnalyticsStatAppReviewsRatedApp:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Reviews - Rated App"];
            [instructions addSuperPropertyToFlag:@"rated_app"];
            [instructions.peoplePropertiesToAssign setValue:@(YES) forKey:@"rated_app"];
            break;
        case WPAnalyticsStatAppReviewsDeclinedToRateApp:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Reviews - Declined to Rate App"];
            [instructions addSuperPropertyToFlag:@"declined_to_rate_app"];
            [instructions.peoplePropertiesToAssign setValue:@(YES) forKey:@"declined_to_rate_app"];
            break;
        case WPAnalyticsStatAppReviewsOpenedFeedbackScreen:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Reviews - Opened Feedback Screen"];
            [instructions addSuperPropertyToFlag:@"opened_feedback_screen_through_app_review_tool"];
            [instructions.peoplePropertiesToAssign setValue:@(YES) forKey:@"opened_feedback_screen_through_app_review_tool"];
            break;
        case WPAnalyticsStatAppReviewsSentFeedback:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Reviews - Sent Feedback"];
            [instructions addSuperPropertyToFlag:@"sent_feedback_through_app_review_tool"];
            [instructions.peoplePropertiesToAssign setValue:@(YES) forKey:@"sent_feedback_through_app_review_tool"];
            break;
        case WPAnalyticsStatAppReviewsCanceledFeedbackScreen:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Reviews - Canceled Sending Feedback After Opening Feedback Screen"];
            break;
        case WPAnalyticsStatAppReviewsLikedApp:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Reviews - Liked App"];
            [instructions addSuperPropertyToFlag:@"indicated_they_liked_app_when_prompted"];
            [instructions.peoplePropertiesToAssign setValue:@(YES) forKey:@"indicated_they_liked_app_when_prompted"];
            break;
        case WPAnalyticsStatAppReviewsDidntLikeApp:
            instructions = [WPAnalyticsTrackerMixpanelInstructionsForStat mixpanelInstructionsForEventName:@"Reviews - Didn't Like App"];
            [instructions addSuperPropertyToFlag:@"indicated_they_didnt_like_app_when_prompted"];
            [instructions.peoplePropertiesToAssign setValue:@(YES) forKey:@"indicated_they_didnt_like_app_when_prompted"];
            break;
        default:
            break;
    }

    instructions.stat = stat;

    return instructions;
}

#pragma mark - Deferred Property Related Methods

- (id)property:(NSString *)property forStat:(WPAnalyticsStat)stat
{
    NSMutableDictionary *properties = [_aggregatedStatProperties objectForKey:[self convertWPStatToString:stat]];
    return properties[property];
}

- (void)saveProperty:(NSString *)property withValue:(id)value forStat:(WPAnalyticsStat)stat
{
    NSMutableDictionary *properties = [_aggregatedStatProperties objectForKey:[self convertWPStatToString:stat]];
    if (properties == nil) {
        properties = [[NSMutableDictionary alloc] init];
        [_aggregatedStatProperties setValue:properties forKey:[self convertWPStatToString:stat]];
    }

    properties[property] = value;
}

- (NSDictionary *)propertiesForStat:(WPAnalyticsStat)stat
{
    return [_aggregatedStatProperties objectForKey:[self convertWPStatToString:stat]];
}

- (void)incrementProperty:(NSString *)property forStat:(WPAnalyticsStat)stat
{
    NSNumber *currentValue = [self property:property forStat:stat];
    int newValue = 1;
    if (currentValue != nil) {
        newValue = [currentValue intValue];
        newValue++;
    }

    [self saveProperty:property withValue:@(newValue) forStat:stat];
}

- (void)incrementSessionCount
{
    NSInteger sessionCount = [[[[Mixpanel sharedInstance] currentSuperProperties] numberForKey:@"session_count"] integerValue];
    sessionCount++;

    NSMutableDictionary *superProperties = [[NSMutableDictionary alloc] initWithDictionary:[Mixpanel sharedInstance].currentSuperProperties];
    superProperties[@"session_count"] = @(sessionCount);
    [[Mixpanel sharedInstance] registerSuperProperties:superProperties];
}

@end
