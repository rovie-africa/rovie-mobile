//
//  ContactsOffload.m
//  MinisApp
//
//  Native offload handler for `apple-contacts`.
//  Subcommands: list, search, get, count, create, delete
//

#import <Foundation/Foundation.h>
#import <Contacts/Contacts.h>
#import "ContactsOffload.h"
#import "NativeOffloadUtils.h"
#include "kernel/native_offload.h"
#include <unistd.h>

static NSString *const TOOL_NAME = @"apple-contacts";

static NSString *const HELP_TEXT =
    @"apple-contacts - Query and manage iOS contacts\n"
     "\n"
     "USAGE:\n"
     "  apple-contacts <command> [options]\n"
     "\n"
     "COMMANDS:\n"
     "  list        List contacts (default: limit 50)\n"
     "  search      Search contacts by name, phone number, or email\n"
     "  get         Get detailed contact information by ID\n"
     "  count       Get total number of contacts\n"
     "  create      Create a new contact\n"
     "  delete      Delete a contact by ID\n"
     "\n"
     "OPTIONS:\n"
     "  --help, -h          Show this help message\n"
     "  --compact           Minimize JSON output\n"
     "  -q, --quiet         Output only data field\n"
     "  --limit <N>         Maximum number of contacts to return (default: 50)\n"
     "  --id <contact_id>   Target contact identifier\n"
     "\n"
     "SEARCH OPTIONS:\n"
     "  <query>             Search text (or use --query <text>)\n"
     "  --query, -s <text>  Search query\n"
     "\n"
     "CREATE OPTIONS:\n"
     "  --first <name>      First / given name\n"
     "  --last <name>       Last / family name\n"
     "  --phone <number>    Phone number (mobile)\n"
     "  --email <address>   Email address\n"
     "  --org <company>     Organization / company name\n"
     "  --title <title>     Job title\n"
     "\n"
     "EXAMPLES:\n"
     "  apple-contacts list --limit 20\n"
     "  apple-contacts search \"John\"\n"
     "  apple-contacts search \"+234\"\n"
     "  apple-contacts get --id \"177C10E0-4217-49C3-AF33-5A4F73EE3742\"\n"
     "  apple-contacts create --first \"Ada\" --last \"Lovelace\" --phone \"+2348012345678\"\n";

static CNContactStore *contact_store(void) {
    static CNContactStore *store = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = [[CNContactStore alloc] init];
    });
    return store;
}

static NSArray<id<CNKeyDescriptor>> *keys_to_fetch(void) {
    return @[
        [CNContactFormatter descriptorForRequiredKeysForStyle:CNContactFormatterStyleFullName],
        CNContactIdentifierKey,
        CNContactGivenNameKey,
        CNContactFamilyNameKey,
        CNContactMiddleNameKey,
        CNContactNicknameKey,
        CNContactOrganizationNameKey,
        CNContactJobTitleKey,
        CNContactDepartmentNameKey,
        CNContactPhoneNumbersKey,
        CNContactEmailAddressesKey,
        CNContactPostalAddressesKey,
        CNContactBirthdayKey
    ];
}

static NSDictionary *serialize_contact(CNContact *c) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"id"] = c.identifier ?: @"";
    dict[@"first_name"] = c.givenName ?: @"";
    dict[@"last_name"] = c.familyName ?: @"";
    dict[@"middle_name"] = c.middleName ?: @"";
    dict[@"nickname"] = c.nickname ?: @"";
    dict[@"organization"] = c.organizationName ?: @"";
    dict[@"job_title"] = c.jobTitle ?: @"";
    dict[@"department"] = c.departmentName ?: @"";

    NSString *fullName = [CNContactFormatter stringFromContact:c style:CNContactFormatterStyleFullName];
    if (!fullName || fullName.length == 0) {
        NSString *combined = [NSString stringWithFormat:@"%@ %@", c.givenName ?: @"", c.familyName ?: @""];
        fullName = [combined stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    dict[@"full_name"] = fullName ?: @"";

    NSMutableArray *phones = [NSMutableArray array];
    for (CNLabeledValue<CNPhoneNumber *> *phone in c.phoneNumbers) {
        NSString *label = [CNLabeledValue localizedStringForLabel:phone.label] ?: @"phone";
        NSString *number = phone.value.stringValue ?: @"";
        if (number.length > 0) {
            [phones addObject:@{ @"label": label, @"number": number }];
        }
    }
    dict[@"phone_numbers"] = phones;

    NSMutableArray *emails = [NSMutableArray array];
    for (CNLabeledValue<NSString *> *email in c.emailAddresses) {
        NSString *label = [CNLabeledValue localizedStringForLabel:email.label] ?: @"email";
        NSString *addr = email.value ?: @"";
        if (addr.length > 0) {
            [emails addObject:@{ @"label": label, @"email": addr }];
        }
    }
    dict[@"email_addresses"] = emails;

    NSMutableArray *addresses = [NSMutableArray array];
    for (CNLabeledValue<CNPostalAddress *> *addr in c.postalAddresses) {
        NSString *label = [CNLabeledValue localizedStringForLabel:addr.label] ?: @"address";
        CNPostalAddress *val = addr.value;
        NSString *formatted = [NSString stringWithFormat:@"%@, %@, %@ %@, %@",
                               val.street ?: @"", val.city ?: @"", val.state ?: @"", val.postalCode ?: @"", val.country ?: @""];
        [addresses addObject:@{ @"label": label, @"formatted": formatted }];
    }
    dict[@"postal_addresses"] = addresses;

    if (c.birthday) {
        dict[@"birthday"] = [NSString stringWithFormat:@"%04ld-%02ld-%02ld", (long)c.birthday.year, (long)c.birthday.month, (long)c.birthday.day];
    }

    return dict;
}

static BOOL check_or_request_contacts_permission(int stdout_fd, BOOL compact, BOOL quiet, NSString *subcmd) {
    CNAuthorizationStatus status = [CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts];
    if (status == CNAuthorizationStatusAuthorized) {
        return YES;
    }

    if (status == CNAuthorizationStatusNotDetermined) {
        __block BOOL granted = NO;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [contact_store() requestAccessForEntityType:CNEntityTypeContacts completionHandler:^(BOOL g, NSError * _Nullable error) {
            granted = g;
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
        if (granted) return YES;
    }

    NSDictionary *err = noff_json_error(TOOL_NAME, subcmd,
                                         NOFF_ERR_AUTHORIZATION_DENIED,
                                         @"Access to Contacts was denied. Please grant Contacts permission in iOS Settings → Privacy & Security → Contacts → Rovie.");
    noff_emit_json(stdout_fd, err, compact, quiet);
    return NO;
}

static int cmd_list(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *limitStr = noff_find_arg(argc, argv, "--limit");
    NSUInteger limit = limitStr ? [limitStr integerValue] : 50;
    if (limit <= 0) limit = 50;

    CNContactFetchRequest *request = [[CNContactFetchRequest alloc] initWithKeysToFetch:keys_to_fetch()];
    request.sortOrder = CNContactSortOrderUserDefault;

    NSMutableArray *contacts = [NSMutableArray array];
    NSError *error = nil;

    BOOL success = [contact_store() enumerateContactsWithFetchRequest:request error:&error usingBlock:^(CNContact *contact, BOOL *stop) {
        [contacts addObject:serialize_contact(contact)];
        if (contacts.count >= limit) {
            *stop = YES;
        }
    }];

    if (!success) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"list",
                                             NOFF_ERR_INTERNAL_ERROR,
                                             error.localizedDescription ?: @"Failed to enumerate contacts.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    NSDictionary *data = @{
        @"count": @(contacts.count),
        @"limit": @(limit),
        @"contacts": contacts
    };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"list", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_search(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *query = noff_find_arg(argc, argv, "--query");
    if (!query) query = noff_find_arg(argc, argv, "-s");
    if (!query) {
        NSArray<NSString *> *posArgs = noff_positional_args(argc, argv);
        if (posArgs.count > 0) {
            query = [posArgs componentsJoinedByString:@" "];
        }
    }

    if (!query || query.length == 0) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"search",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Search query required. Usage: apple-contacts search <query>");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSString *limitStr = noff_find_arg(argc, argv, "--limit");
    NSUInteger limit = limitStr ? [limitStr integerValue] : 50;
    if (limit <= 0) limit = 50;

    NSError *error = nil;
    NSPredicate *predicate = [CNContact predicateForContactsMatchingName:query];
    NSArray<CNContact *> *matches = [contact_store() unifiedContactsMatchingPredicate:predicate keysToFetch:keys_to_fetch() error:&error];

    NSMutableDictionary<NSString *, CNContact *> *uniqueResults = [NSMutableDictionary dictionary];
    for (CNContact *c in matches) {
        uniqueResults[c.identifier] = c;
    }

    // If query has digits or '@', also scan phone numbers and email addresses
    NSCharacterSet *digitSet = [NSCharacterSet decimalDigitCharacterSet];
    BOOL hasDigits = [query rangeOfCharacterFromSet:digitSet].location != NSNotFound;
    BOOL hasAt = [query containsString:@"@"];

    if ((hasDigits || hasAt || uniqueResults.count == 0) && uniqueResults.count < limit) {
        CNContactFetchRequest *fetchReq = [[CNContactFetchRequest alloc] initWithKeysToFetch:keys_to_fetch()];
        NSString *needle = [query lowercaseString];

        [contact_store() enumerateContactsWithFetchRequest:fetchReq error:nil usingBlock:^(CNContact *contact, BOOL *stop) {
            BOOL matched = NO;
            for (CNLabeledValue<CNPhoneNumber *> *p in contact.phoneNumbers) {
                if ([p.value.stringValue containsString:query]) {
                    matched = YES;
                    break;
                }
            }
            if (!matched) {
                for (CNLabeledValue<NSString *> *e in contact.emailAddresses) {
                    if ([e.value.lowercaseString containsString:needle]) {
                        matched = YES;
                        break;
                    }
                }
            }
            if (!matched && (contact.organizationName && [contact.organizationName.lowercaseString containsString:needle])) {
                matched = YES;
            }

            if (matched) {
                uniqueResults[contact.identifier] = contact;
                if (uniqueResults.count >= limit) {
                    *stop = YES;
                }
            }
        }];
    }

    NSMutableArray *contacts = [NSMutableArray array];
    for (CNContact *c in uniqueResults.allValues) {
        [contacts addObject:serialize_contact(c)];
        if (contacts.count >= limit) break;
    }

    NSDictionary *data = @{
        @"query": query,
        @"count": @(contacts.count),
        @"contacts": contacts
    };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"search", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_get(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *contactId = noff_find_arg(argc, argv, "--id");
    if (!contactId) {
        NSArray<NSString *> *pos = noff_positional_args(argc, argv);
        if (pos.count > 0) contactId = pos[0];
    }

    if (!contactId || contactId.length == 0) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"get",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Contact ID required. Usage: apple-contacts get --id <contact_id>");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSError *error = nil;
    CNContact *contact = [contact_store() unifiedContactWithIdentifier:contactId keysToFetch:keys_to_fetch() error:&error];
    if (!contact) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"get",
                                             NOFF_ERR_NO_DATA,
                                             [NSString stringWithFormat:@"Contact not found: %@", contactId]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    NSDictionary *data = @{ @"contact": serialize_contact(contact) };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"get", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_count(int stdout_fd, BOOL compact, BOOL quiet) {
    __block NSUInteger count = 0;
    CNContactFetchRequest *request = [[CNContactFetchRequest alloc] initWithKeysToFetch:@[]];
    NSError *error = nil;

    BOOL success = [contact_store() enumerateContactsWithFetchRequest:request error:&error usingBlock:^(CNContact *contact, BOOL *stop) {
        count++;
    }];

    if (!success) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"count",
                                             NOFF_ERR_INTERNAL_ERROR,
                                             error.localizedDescription ?: @"Failed to count contacts.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    NSDictionary *data = @{ @"total": @(count) };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"count", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_create(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *first = noff_find_arg(argc, argv, "--first");
    NSString *last = noff_find_arg(argc, argv, "--last");
    NSString *phone = noff_find_arg(argc, argv, "--phone");
    NSString *email = noff_find_arg(argc, argv, "--email");
    NSString *org = noff_find_arg(argc, argv, "--org");
    NSString *title = noff_find_arg(argc, argv, "--title");

    if ((!first || first.length == 0) && (!last || last.length == 0) && (!org || org.length == 0)) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"create",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"At least a first name, last name, or organization is required.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    CNMutableContact *c = [[CNMutableContact alloc] init];
    if (first) c.givenName = first;
    if (last) c.familyName = last;
    if (org) c.organizationName = org;
    if (title) c.jobTitle = title;

    if (phone && phone.length > 0) {
        CNLabeledValue *phoneVal = [CNLabeledValue labeledValueWithLabel:CNLabelPhoneNumberMobile
                                                                  value:[CNPhoneNumber phoneNumberWithStringValue:phone]];
        c.phoneNumbers = @[phoneVal];
    }

    if (email && email.length > 0) {
        CNLabeledValue *emailVal = [CNLabeledValue labeledValueWithLabel:CNLabelHome value:email];
        c.emailAddresses = @[emailVal];
    }

    CNSaveRequest *saveRequest = [[CNSaveRequest alloc] init];
    [saveRequest addContact:c toContainerWithIdentifier:nil];

    NSError *error = nil;
    if (![contact_store() executeSaveRequest:saveRequest error:&error]) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"create",
                                             NOFF_ERR_INTERNAL_ERROR,
                                             error.localizedDescription ?: @"Failed to save new contact.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    NSDictionary *data = @{
        @"created": @YES,
        @"contact": serialize_contact(c)
    };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"create", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_delete(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *contactId = noff_find_arg(argc, argv, "--id");
    if (!contactId) {
        NSArray<NSString *> *pos = noff_positional_args(argc, argv);
        if (pos.count > 0) contactId = pos[0];
    }

    if (!contactId || contactId.length == 0) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"delete",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Contact ID required. Usage: apple-contacts delete --id <contact_id>");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSError *error = nil;
    CNContact *contact = [contact_store() unifiedContactWithIdentifier:contactId keysToFetch:keys_to_fetch() error:&error];
    if (!contact) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"delete",
                                             NOFF_ERR_NO_DATA,
                                             [NSString stringWithFormat:@"Contact not found: %@", contactId]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    CNMutableContact *mutableContact = [contact mutableCopy];
    CNSaveRequest *saveRequest = [[CNSaveRequest alloc] init];
    [saveRequest deleteContact:mutableContact];

    if (![contact_store() executeSaveRequest:saveRequest error:&error]) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"delete",
                                             NOFF_ERR_INTERNAL_ERROR,
                                             error.localizedDescription ?: @"Failed to delete contact.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    NSDictionary *data = @{
        @"deleted": @YES,
        @"id": contactId,
        @"full_name": [CNContactFormatter stringFromContact:contact style:CNContactFormatterStyleFullName] ?: @""
    };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"delete", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int contacts_handler(int argc, char **argv,
                            int stdin_fd, int stdout_fd, int stderr_fd) {
    if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }

    BOOL compact = noff_has_flag(argc, argv, "--compact");
    BOOL quiet = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");

    NSString *subcmd = noff_get_subcommand(argc, argv);
    if (!subcmd) {
        subcmd = @"list";
    }

    if (!check_or_request_contacts_permission(stdout_fd, compact, quiet, subcmd)) {
        return NOFF_EXIT_AUTH_DENIED;
    }

    if ([subcmd isEqualToString:@"list"]) {
        return cmd_list(argc, argv, stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"search"]) {
        return cmd_search(argc, argv, stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"get"]) {
        return cmd_get(argc, argv, stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"count"]) {
        return cmd_count(stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"create"]) {
        return cmd_create(argc, argv, stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"delete"]) {
        return cmd_delete(argc, argv, stdout_fd, compact, quiet);
    }

    noff_emit_help(stderr_fd, HELP_TEXT);
    NSDictionary *err = noff_json_error(TOOL_NAME, subcmd,
                                         NOFF_ERR_INVALID_ARGS,
                                         [NSString stringWithFormat:@"Unknown command '%@'. Valid commands: list, search, get, count, create, delete.", subcmd]);
    noff_emit_json(stdout_fd, err, compact, quiet);
    return NOFF_EXIT_INVALID_ARGS;
}

void contacts_offload_register(void) {
    int err = native_offload_add_handler("apple-contacts", contacts_handler);
    if (err == 0) {
        noff_ensure_guest_stub("/usr/local/bin/apple-contacts");
        NSLog(@"NativeOffloads: apple-contacts handler registered");
    } else {
        NSLog(@"NativeOffloads: failed to register apple-contacts handler (err=%d)", err);
    }
}

