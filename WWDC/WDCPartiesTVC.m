//
//  WDCPartiesTVC.m
//  WWDC
//
//  Created by Genady Okrain on 5/17/14.
//  Copyright (c) 2014 Sugar So Studio. All rights reserved.
//

#import <MessageUI/MessageUI.h>
#import "GAI.h"
#import "GAIFields.h"
#import "GAIDictionaryBuilder.h"
#import "JVObserver.h"
#import "WDCPartiesTVC.h"
#import "WDCParty.h"
#import "WDCParties.h"
#import "WDCPartyTVC.h"
#import "WDCPartyTableViewController.h"
#import "WDCMapDayViewController.h"
#import "Parties-Swift.h"
@import CoreLocation;

@interface WDCPartiesTVC () <MFMailComposeViewControllerDelegate>

@property (strong, nonatomic) NSArray *parties;
@property (strong, nonatomic) NSArray *filteredParties;
@property (weak, nonatomic) IBOutlet UISegmentedControl *goingSegmentedControl;
@property (strong, nonatomic) NSMutableArray *observers;
@property (strong, nonatomic) CLLocationManager *locationManager;

@end

@implementation WDCPartiesTVC

- (void)viewDidLoad
{
    [super viewDidLoad];

    // PaintCode
    [self.goingSegmentedControl setImage:[Assets imageOfTogglegoingWithInitColor:[UIColor whiteColor]] forSegmentAtIndex:1];
    [self.goingSegmentedControl setImage:[Assets imageOfToggleallactive] forSegmentAtIndex:0];

    // Google
    id tracker = [[GAI sharedInstance] defaultTracker];
    [tracker set:kGAIScreenName value:@"WDCPartiesTVC"];
    [tracker send:[[GAIDictionaryBuilder createAppView] build]];

    NSInteger selected = [[[NSUserDefaults alloc] initWithSuiteName:@"group.so.sugar.SFParties"] integerForKey:@"selected"];
    if (selected) {
        self.goingSegmentedControl.selectedSegmentIndex = selected;
    }

    self.tableView.tableFooterView = [[UIView alloc] init];

    self.observers = [[NSMutableArray alloc] init];
    self.tableView.contentOffset = CGPointMake(0, -self.refreshControl.frame.size.height);
    [self.refreshControl beginRefreshing];
    [self refresh:self];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    [self.tableView deselectRowAtIndexPath:[self.tableView indexPathForSelectedRow] animated:animated];
    [self updateFilteredParties];

    // ask for location once
    CLAuthorizationStatus authorizationStatus = [CLLocationManager authorizationStatus];
    if (authorizationStatus == kCLAuthorizationStatusNotDetermined) {
        self.locationManager = [[CLLocationManager alloc] init];
        [self.locationManager requestWhenInUseAuthorization];
        [[Mixpanel sharedInstance] track:@"CLLocationManager" properties:@{@"authorizationStatus": @"NotDetermined"}];
    } else if (authorizationStatus == kCLAuthorizationStatusRestricted) {
        [[Mixpanel sharedInstance] track:@"CLLocationManager" properties:@{@"authorizationStatus": @"Restricted"}];
    } else if (authorizationStatus == kCLAuthorizationStatusDenied) {
        [[Mixpanel sharedInstance] track:@"CLLocationManager" properties:@{@"authorizationStatus": @"Denied"}];
    } else if (authorizationStatus == kCLAuthorizationStatusAuthorizedAlways) {
        [[Mixpanel sharedInstance] track:@"CLLocationManager" properties:@{@"authorizationStatus": @"AuthorizedAlways"}];
    } else if (authorizationStatus == kCLAuthorizationStatusAuthorizedWhenInUse) {
        [[Mixpanel sharedInstance] track:@"CLLocationManager" properties:@{@"authorizationStatus": @"AuthorizedWhenInUse"}];
    }
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id <UIViewControllerTransitionCoordinator>)coordinator
{
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView reloadData];
    });
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (IBAction)refresh:(id)sender
{
    [[WDCParties sharedInstance] refreshWithBlock:^(BOOL succeeded, NSArray *parties) {
        if (succeeded) {
            NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
            for (WDCParty *party in parties) {
                if (![dict objectForKey:[party sortDate]]) {
                    [dict setObject:[[NSMutableArray alloc] init] forKey:[party sortDate]];
                }
                [[dict objectForKey:[party sortDate]] addObject:party];
            }
            NSArray *sortedKeys = [[dict allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
            NSMutableArray *array = [[NSMutableArray alloc] init];
            for (NSString *key in sortedKeys) {
                NSArray *sortDesc = @[
                                      [NSSortDescriptor sortDescriptorWithKey:@"startDate" ascending:YES],
                                      [NSSortDescriptor sortDescriptorWithKey:@"title" ascending:YES selector:@selector(caseInsensitiveCompare:)]
                                      ];
                [array addObject:[[dict objectForKey:key] sortedArrayUsingDescriptors:sortDesc]];
            }
            self.parties = [array copy];
            [self updateFilteredParties];
            if ([WDCParties sharedInstance].disableCache) {
                [self.refreshControl endRefreshing];
            }
            [[Mixpanel sharedInstance] track:@"WDCParties" properties:@{@"refresh": @"OK", @"count": [NSNumber numberWithInteger:parties.count]}];
            [[Mixpanel sharedInstance].people increment:@"WDCParties.refresh.ok" by:@1];
        } else {
            [self.refreshControl endRefreshing];
            [[Mixpanel sharedInstance] track:@"WDCParties" properties:@{@"refresh": @"FAILED"}];
            [[Mixpanel sharedInstance].people increment:@"WDCParties.refresh.failed" by:@1];
        }
    }];
}

- (IBAction)updateSegment:(UISegmentedControl *)sender
{
    [self updateFilteredParties];
    NSUserDefaults *userDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"group.so.sugar.SFParties"];
    [userDefaults setInteger:sender.selectedSegmentIndex forKey:@"selected"];
    [userDefaults synchronize];
    [[Mixpanel sharedInstance] track:@"updateSegment" properties:@{@"selected": [NSNumber numberWithInteger:sender.selectedSegmentIndex]}];
    [[Mixpanel sharedInstance].people increment:@"updateSegment.selected" by:@1];
}

- (void)updateFilteredParties
{
    if (self.goingSegmentedControl.selectedSegmentIndex == 0) {
        self.filteredParties = self.parties;
        self.tableView.scrollEnabled = YES;
    } else {
        NSMutableArray *filteredPartiesMutable = [[NSMutableArray alloc] init];
        for (NSArray *array in self.parties) {
            NSMutableArray *mutableArray = [[NSMutableArray alloc] init];
            for (WDCParty *party in array) {
                if ([[WDCParties sharedInstance].going indexOfObject:party.objectId] != NSNotFound) {
                    [mutableArray addObject:party];
                }
            }
            if ([mutableArray count]) {
                [filteredPartiesMutable addObject:[mutableArray copy]];
            }
        }
        self.filteredParties = [filteredPartiesMutable copy];
        if ([self.filteredParties count] == 0) {
            self.tableView.scrollEnabled = NO;
        } else {
            self.tableView.scrollEnabled = YES;
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView reloadData];
    });
}

- (IBAction)addParty:(UIBarButtonItem *)sender
{
    if ([MFMailComposeViewController canSendMail]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Please provide as many details as possible", nil) message:NSLocalizedString(@"We would really appreciate if you won't send us an empty mail", nil) preferredStyle:UIAlertControllerStyleActionSheet];
        UIAlertAction *ok = [UIAlertAction actionWithTitle:NSLocalizedString(@"Suggest a Party", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
            MFMailComposeViewController *mailVC = [[MFMailComposeViewController alloc] init];
            mailVC.mailComposeDelegate = self;
            [mailVC setSubject:NSLocalizedString(@"Suggest a Party", nil)];
            [mailVC setToRecipients:[NSArray arrayWithObjects:@"team@sugar.so", nil]];
            [self presentViewController:mailVC animated:YES completion:nil];
        }];
        UIAlertAction *cancel = [UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
            [alert dismissViewControllerAnimated:YES completion:nil];
        }];
        [alert addAction:ok];
        [alert addAction:cancel];
        alert.modalPresentationStyle = UIModalPresentationPopover;
        UIPopoverPresentationController *popoverPresentationController = [alert popoverPresentationController];
        popoverPresentationController.barButtonItem = sender;
        [self presentViewController:alert animated:YES completion:nil];
        [[Mixpanel sharedInstance] track:@"addParty" properties:@{@"canSendMail": @"OK"}];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Please configure mail account", nil) message:nil preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *ok = [UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
            [alert dismissViewControllerAnimated:YES completion:nil];
        }];
        [alert addAction:ok];
        [self presentViewController:alert animated:YES completion:nil];
        [[Mixpanel sharedInstance] track:@"addParty" properties:@{@"canSendMail": @"Error"}];
    }
}

- (void)mailComposeController:(MFMailComposeViewController*)controller didFinishWithResult:(MFMailComposeResult)result error:(NSError*)error
{
    switch (result) {
        case MFMailComposeResultCancelled:
            [[Mixpanel sharedInstance] track:@"mailComposeController" properties:@{@"result": @"Cancelled"}];
            NSLog(@"Mail cancelled: you cancelled the operation and no email message was queued.");
            break;
        case MFMailComposeResultSaved:
            [[Mixpanel sharedInstance] track:@"mailComposeController" properties:@{@"result": @"Saved"}];
            NSLog(@"Mail saved: you saved the email message in the drafts folder.");
            break;
        case MFMailComposeResultSent:
            [[Mixpanel sharedInstance] track:@"mailComposeController" properties:@{@"result": @"Sent"}];
            NSLog(@"Mail send: the email message is queued in the outbox. It is ready to send.");
            break;
        case MFMailComposeResultFailed:
            [[Mixpanel sharedInstance] track:@"mailComposeController" properties:@{@"result": @"Failed"}];
            NSLog(@"Mail failed: the email message was not saved or queued, possibly due to an error.");
            break;
        default:
            [[Mixpanel sharedInstance] track:@"mailComposeController" properties:@{@"result": @"Other"}];
            NSLog(@"Mail not sent.");
            break;
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (IBAction)sugarSo:(id)sender
{
    NSURL *url = [NSURL URLWithString: @"http://sugar.so"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[Mixpanel sharedInstance] track:@"sugarSo" properties:@{@"canOpenURL": @"OK"}];
        [[Mixpanel sharedInstance].people increment:@"sugarSo.canOpenURL" by:@1];
        [[UIApplication sharedApplication] openURL:url];
    }
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    if ((self.goingSegmentedControl.selectedSegmentIndex == 1) && ([self.filteredParties count] == 0)) {
        return 1;
    } else {
        return [self.filteredParties count]+1;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if ((section == [self.filteredParties count]) || ((self.goingSegmentedControl.selectedSegmentIndex == 1) && ([self.filteredParties count] == 0))) {
        return 1;
    } else {
        return [self.filteredParties[section] count];
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    CGFloat height = [super tableView:tableView heightForRowAtIndexPath:indexPath];

    if (self.traitCollection.verticalSizeClass == UIUserInterfaceSizeClassCompact) {
        height = 90;
    }

    if ((self.goingSegmentedControl.selectedSegmentIndex == 1) && ([self.filteredParties count] == 0)) {
        height = [[UIScreen mainScreen] bounds].size.height-2*(self.navigationController.navigationBar.frame.size.height+[UIApplication sharedApplication].statusBarFrame.size.height);
    } else if (indexPath.section == [self.filteredParties count]) {
        height = 55;
    }

    return height;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    CGFloat height = [super tableView:tableView heightForHeaderInSection:section];

    if (section == [self.filteredParties count]) {
        height = 10;
    } else {
        height = 40;
    }

    return height;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell;

    if ((self.goingSegmentedControl.selectedSegmentIndex == 1) && ([self.filteredParties count] == 0)) {
        cell = [tableView dequeueReusableCellWithIdentifier:@"empty" forIndexPath:indexPath];
    } else if ((indexPath.section == [self.filteredParties count]) && (indexPath.row == 0)) {
        cell = [tableView dequeueReusableCellWithIdentifier:@"credits" forIndexPath:indexPath];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        WDCPartyTVC *partyCell = [tableView dequeueReusableCellWithIdentifier:@"party" forIndexPath:indexPath];
        WDCParty *party = (self.filteredParties[indexPath.section])[indexPath.row];
        partyCell.titleLabel.text = party.title;
        partyCell.hoursLabel.text = [party hours];
        if ([[WDCParties sharedInstance].going indexOfObject:party.objectId] == NSNotFound) {
            partyCell.goingView.hidden = YES;
        } else {
            partyCell.goingView.hidden = NO;
        }
        
        partyCell.iconImageView.image = party.icon;
        if (!party.icon) {
            __weak typeof(party) weakParty = party;
            JVObserver *observer = [JVObserver observerForObject:party keyPath:@"icon" target:self block:^(__weak typeof(self) self) {
                if (weakParty.icon) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.tableView reloadData];
                    });
                };
            }];
            [self.observers addObject:observer];
        }

        [partyCell.seperator removeFromSuperview];
        if (indexPath.row != [self.filteredParties[indexPath.section] count]-1) {
            partyCell.seperator = [[UIView alloc] initWithFrame:CGRectMake(7, partyCell.frame.size.height-1, partyCell.frame.size.width-7*2, 1)];
            partyCell.seperator.opaque = YES;
            partyCell.seperator.backgroundColor = [UIColor colorWithRed:235.0f/255.0f green:235.0f/255.0f blue:235.0f/255.0f alpha:1.0f];
            [partyCell addSubview:partyCell.seperator];
        } else {
            partyCell.seperator = [[UIView alloc] initWithFrame:CGRectMake(7, partyCell.frame.size.height-1, partyCell.frame.size.width-7*2, 1.0f)];
            partyCell.seperator.opaque = YES;
            partyCell.seperator.backgroundColor = [UIColor whiteColor];
            [partyCell addSubview:partyCell.seperator];
        }
        cell = partyCell;
    }

    return cell;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    UIView *view;
    if (section != [self.filteredParties count]) {
        view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.frame.size.width, 40.0f)];
        UIView *bgView = [[UIView alloc] initWithFrame:CGRectMake(7, 0, tableView.frame.size.width-7*2, 40.0f)];
        bgView.backgroundColor = [UIColor colorWithRed:247.0f/255.0f green:247.0f/255.0f blue:247.0f/255.0f alpha:1.0f];
        [view addSubview:bgView];
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(22, 0, tableView.frame.size.width-22*2, 40.0f)];
        label.font = [UIFont fontWithName:@"HelveticaNeue-Regular" size:15.0f];
        label.text = [((WDCParty *)[self.filteredParties[section] lastObject]) date];
        label.textColor = [UIColor colorWithRed:117.0f/255.0f green:117.0f/255.0f blue:117.0f/255.0f alpha:1.0f];
        [view addSubview:label];
        UIButton *button = [UIButton buttonWithType:UIButtonTypeRoundedRect];
        [button setFrame:CGRectMake(tableView.frame.size.width-40.0f, 0.0f, 20, 40.0f)];
        [button setImage:[Assets imageOfMapWithFrame:button.bounds] forState:UIControlStateNormal];
        [button addTarget:self action:@selector(buttonClicked:) forControlEvents:UIControlEventTouchDown];
        button.tag = section;
        [view addSubview:button];
    } else {
        view = [[UIView alloc] init];
    }
    return view;
}

- (void)buttonClicked:(UIButton *)sender
{
    [self performSegueWithIdentifier:@"map" sender:[NSNumber numberWithInteger:sender.tag]];
}

#pragma mark - Navigation

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender
{
    if ([segue.identifier isEqualToString:@"party"]) {
        NSIndexPath *indexPath = [self.tableView indexPathForSelectedRow];
        UINavigationController *navigationController = segue.destinationViewController;
        WDCPartyTableViewController *destController = (WDCPartyTableViewController *)[navigationController topViewController];
        WDCParty *party = (self.filteredParties[indexPath.section])[indexPath.row];
        destController.party = party;
        [[Mixpanel sharedInstance] track:@"WDCPartiesTVC" properties:@{@"SegueParty": party.title}];
        [[Mixpanel sharedInstance].people increment:@"WDCPartiesTVC.SegueParty" by:@1];
    } else if ([segue.identifier isEqualToString:@"map"]) {
        if ([sender isKindOfClass:[NSNumber class]]) {
            NSInteger tag = [(NSNumber *)sender integerValue];
            UINavigationController *navigationController = segue.destinationViewController;
            WDCMapDayViewController *destController = (WDCMapDayViewController *)[navigationController topViewController];
            destController.parties = self.filteredParties[tag];
            [[Mixpanel sharedInstance] track:@"WDCPartiesTVC" properties:@{@"SegueMap": [NSNumber numberWithInteger:tag]}];
            [[Mixpanel sharedInstance].people increment:@"WDCPartiesTVC.SegueMap" by:@1];
        }
    }
}

@end
