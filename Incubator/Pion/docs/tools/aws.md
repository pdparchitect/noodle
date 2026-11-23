# AWS

Pion has two AWS tools. Each signs in through your organisation's
[IAM Identity Center](https://docs.aws.amazon.com/singlesignon/latest/userguide/what-is.html)
with a permission set of its own, and one connection covers every account you
are assigned:

- **AWS Audit** reads your accounts the way a defender does: who did what in
  [CloudTrail](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-user-guide.html),
  what [GuardDuty](https://docs.aws.amazon.com/guardduty/latest/ug/what-is-guardduty.html),
  [Security Hub](https://docs.aws.amazon.com/securityhub/latest/userguide/what-is-securityhub.html)
  and [IAM Access Analyzer](https://docs.aws.amazon.com/IAM/latest/UserGuide/what-is-access-analyzer.html)
  found, who an access key belongs to, every user's credentials, who holds
  which permissions, instances and security groups open to the internet, and
  CloudWatch Logs Insights queries. It wakes the agents it is assigned to when
  GuardDuty or Security Hub raises a high or critical finding, or CloudTrail
  shows the way in being opened or what follows being hidden. It only reads.
- **AWS Containment** acts on the same accounts to contain an incident: it
  turns off an access key, quarantines a user or role, ends a role's sessions,
  removes a console password, isolates, stops, snapshots or protects an
  instance, takes away an instance's role, blocks S3 public access, restarts
  logging, and archives, reopens or closes findings. What cuts off or restores
  access, stops an instance, hides a finding or deletes something waits for
  your approval.

Neither keeps an access key: each request uses short-lived role credentials
from Identity Center, fetched again before they expire, and the sign-in lasts
as long as your organisation lets a session last. The quick steps are under
**Setup Steps** in **Settings → Tools**. This guide explains them.

The pages they use:

- **Permission sets** and **AWS accounts** in the
  [IAM Identity Center console](https://console.aws.amazon.com/singlesignon),
  for each tool's permission set and who it is assigned to.
- Your **AWS access portal URL**, on the Identity Center dashboard.
- The [GuardDuty](https://console.aws.amazon.com/guardduty) and
  [Security Hub](https://console.aws.amazon.com/securityhub) consoles, to turn
  them on.

## How AWS limits what Pion can do

Each tool signs in as you, approving a code on your organisation's sign-in page
as AWS's own command line does, and then takes one role, the permission set's,
in whichever account a request names. AWS checks that role's policies on every
request: the permission set is all it can do.

- **AWS Audit's permission set** is AWS's read-only **SecurityAudit** policy
  with a small inline policy, so it cannot change anything, whatever Pion asks
  for. Keep it that way: **check-access** warns when the role could make
  changes such as creating users or opening security groups.
- **AWS Containment's permission set** gets only the actions its operations
  take, with IAM attachments limited to AWS's deny-all policies, and nothing on
  Identity Center's own roles. Leave out any statement you do not want agents
  to have.

Both reach only AWS: Identity Center's sign-in at `oidc.REGION.amazonaws.com`,
`portal.sso.REGION.amazonaws.com` and your portal on `awsapps.com`, and then
each service's own host, built from a fixed name and a region Pion checks,
such as `cloudtrail.eu-west-1.amazonaws.com`, `iam.amazonaws.com` or, for S3's
account settings, `ACCOUNT.s3-control.REGION.amazonaws.com`. A bucket's name
only ever goes in the address's path, so no name AWS or an agent gives picks a
host, and a host of any other shape is not signed. When a listing has more
pages, Pion sends AWS's next-page token back to the same host. Neither tool
follows a redirect. Every user, role, instance, bucket, trail and finding they
act on must be in the account named; Pion refuses one from any other before
sending anything.

## Setting it up with least access

1. **Make a permission set** for AWS Audit in IAM Identity Center from the
   AWS managed policy **SecurityAudit**, named such as `SecurityAudit`, with a
   session of an hour or so.
2. **Add an inline policy** to it allowing `logs:StartQuery` and
   `logs:GetQueryResults` for Logs Insights, and `iam:SimulatePrincipalPolicy`
   so **check-access** can tell whether the role could change anything:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Action": ["logs:StartQuery", "logs:GetQueryResults", "iam:SimulatePrincipalPolicy"],
       "Resource": "*"
     }]
   }
   ```

3. **Assign it** to whoever signs in to Pion, in every account to investigate.
   Select them all to cover the organisation.
4. **Turn on what the watch reads**: GuardDuty and Security Hub in each
   account's default region, ideally for the whole organisation from a
   delegated administrator, with Security Hub's
   [cross-region aggregation](https://docs.aws.amazon.com/securityhub/latest/userguide/finding-aggregation.html)
   into that region, and a CloudTrail trail logging every region.
5. **Add the account** with the **AWS access portal URL**, the permission set's
   name as the role, and the region most activity is in. Agents can name any
   other region, and any account.

Then choose **Add & Connect**, check that the code on your organisation's
sign-in page matches the one Pion shows, approve it, and ask an agent to run
**check-access**.

## Coverage you should know

- **Each lookup reads one account and one region.** Most AWS services are
  regional, so silence in the default region is not silence everywhere. Every
  result names the account and region it read; `regions` lists those turned on.
- **IAM, STS, Organizations and console sign-ins are logged in us-east-1.**
  `cloudtrail-events` reads us-east-1 too, unless a region is named, and says
  what that leaves out when one is.
- **CloudTrail's event history keeps 90 days of management events** in each
  region, whether or not a trail is logging, and only one lookup attribute at a
  time. It does not hold data events, such as objects read from S3, which need
  a trail recording them. Pion follows its pages and says when more matched
  than were read.
- **Findings carry their own account and region.** In a delegated
  administrator or aggregating account, GuardDuty's and Security Hub's findings
  include members' and other regions', and each result says whose they are.
  Archived GuardDuty findings, and suppressed or resolved Security Hub ones, are
  left out unless asked for.
- **The credential report may be up to four hours old.** AWS reuses one it made
  recently, so users and keys made since may be missing; the result says when
  it was made.
- **The accounts are those you are assigned.** Accounts of the organisation
  outside your assignment are not reached; **check-access** compares them with
  the organisation's own list where the role may read it.
- **Access through Identity Center is not in IAM.** `iam-access` lists IAM
  users and roles; who holds which permission set is in IAM Identity Center.

## What agents can do

- `accounts`: every account the sign-in covers, which other lookups name.
- `regions`: the regions an account has turned on.
- `cloudtrail-events`: CloudTrail's event history, newest first, by one of
  user, event name, event source, resource or access key, with who acted (root,
  an IAM user, or an assumed role and the role behind it, and from which
  account), the source IP, the agent, whether MFA was used and any error.
- `guardduty-findings`: GuardDuty's findings from a severity, 9 and above being
  critical, with the resource and identity each concerns.
- `securityhub-findings`: Security Hub's active findings by severity and
  workflow status.
- `access-key`: which account a key belongs to and, for a long-term key, which
  user and when, where and with which service it was last used. A temporary
  key is traced to its account, and its use to `cloudtrail-events`.
- `credential-report`: every IAM user's password, keys and MFA.
- `iam-access`: who holds which permissions, full administrators first, and who
  can assume each role.
- `access-analyzer-findings`: resources shared outside the organisation or
  account, from its external access analyzer.
- `ec2-instances` and `open-security-groups`: instances by ID or address, and
  security groups open to the internet over IPv4 or IPv6.
- `logs-insights`: a CloudWatch Logs Insights query, saying when more records
  matched than were returned.
- `security-events`: what the alert watch wakes for, for a window; the last 24
  hours when none is given. It says what it searched, what is off, what it
  could not read and why, and what it does not watch.
- **check-access**: see [When something does not work](#when-something-does-not-work).

## The alert watch

Every five minutes the watch reads, in the default region of up to ten
accounts, the lowest account IDs first, six hours back from the newest it has
seen or from the last check that read a feed whole:

- **Security Hub's active critical and high findings** that are NEW or
  NOTIFIED, by when they were made, as products update their findings every
  day.
- **GuardDuty's high and critical findings** that are not archived, by when
  they were last updated. A finding read from both GuardDuty and Security Hub
  is one.
- **CloudTrail's changes**, in the default region and in us-east-1, up to four
  pages of each a check, for:
  - any root activity that changes something, and root signing in;
  - an IAM user signing in to the console without MFA;
  - an IAM user, console password or access key made;
  - AdministratorAccess, IAMFullAccess or PowerUserAccess attached, an inline
    policy allowing every action or all of IAM, or a managed policy's default
    version replaced;
  - a role made assumable by anyone, an account outside those the sign-in
    covers, or an identity provider's tokens for any subject;
  - an MFA device removed;
  - IAM Identity Center permission sets or assignments changed;
  - CloudTrail stopped or a trail deleted or changed, VPC flow logs or a log
    group deleted;
  - GuardDuty, Security Hub, AWS Config or an Access Analyzer turned off, or a
    GuardDuty filter made that archives findings;
  - a bucket policy letting anyone in, a bucket ACL granting everyone access,
    or S3 Block Public Access removed or loosened;
  - a security group opened to the internet, or an EBS snapshot, machine image
    or database snapshot made public;
  - a KMS key disabled, scheduled for deletion or its policy replaced;
  - an account leaving the organisation, or a service control policy removed;
  - a command run on an instance through Systems Manager.

It wakes the agents with a note naming `security-events`. The note carries only
how many, and when: nothing AWS wrote, such as a finding's title or an event's
request, reaches it, and the IDs the watch keeps are digests. Each finding and
event is told once. When one check finds more than it can hand over, 500, each
kind takes its turn, the watch says once that more follow, and the checks after
read again from the oldest left over until all of it is handed over, even
across a check that could not read that feed whole. Security Hub's findings are
read oldest first, and a query larger than a check reads goes on with AWS's own
next-page token for that query, kept between checks, so findings made at the
same moment are never read again and again while the rest wait. If AWS no
longer takes the token, the query is read again from its start, and said. A check that fails keeps nothing of what it read, so the next one
reads the same window again.

**What it does not watch:** regions other than the default, except CloudTrail
in us-east-1, which Security Hub's cross-region aggregation covers for its
findings; medium and low findings; data events and reads, including root's;
failed calls; roles assumed from outside the organisation, which
`cloudtrail-events` finds with `eventName` AssumeRole; and accounts past the
first ten, or not covered by the sign-in.

**When it cannot read a feed**, it says so rather than going quiet: a feed
refused, the role missing in an account, the sign-in failing, more than one
check reads, Security Hub or GuardDuty off, no CloudTrail trail logging, or
more accounts than the watch reads each wake the agents once, and once more
after Pion relaunches if still so. A failure that passes, such as AWS
throttling, holds the watch back for up to half an hour, reading the same
window again. CloudTrail's event history is read newest first, so a window with
more changes than a check reads is said, and `security-events` or
`cloudtrail-events` reads the rest.

## When something does not work

Ask an agent to run **check-access**, for one account or the first five. It
changes nothing, and tries once each:

- who the role is, CloudTrail's event history, IAM, EC2 and CloudWatch Logs;
- whether a CloudTrail trail is logging, for every region and the
  organisation, and to CloudWatch Logs;
- whether GuardDuty is on, with its administrator; Security Hub, with its
  administrator and cross-region aggregation; AWS Config recording; and an
  external access analyzer;
- whether the role could make changes, simulated against its own policies;
- which of the organisation's accounts the sign-in does not cover.

For what does not work it says the permission to add to the permission set, and
any refused call says the same. When AWS throttles requests, Pion waits and
tries again, as AWS's own tools do.

## Reading results

- **Results say what they covered.** Each names its account and region, and
  says when it stopped before the end or matched more than it kept.
- **"No events" is not "none happened".** A search says nothing matched only
  in what it read, in the region it read. A service that is off finds nothing.
- **A caller is the credential used, not the person.** An assumed role's
  session name is what its holder chose; the role behind it, and the
  Identity Center user or federated identity that took it, say who.

## Containing an incident

**AWS Containment** is a separate tool, with its own permission set, so the
audit role stays read-only.

1. **Make a custom permission set** named such as `PionContainment`, with an
   hour's session, and give it only this inline policy, leaving out any
   statement you do not want agents to have:

   ```json
   {"Version":"2012-10-17","Statement":[
    {"Sid":"Read","Effect":"Allow","Resource":"*","Action":["sts:GetCallerIdentity","iam:GetRole","iam:ListAccessKeys","iam:GetAccessKeyLastUsed",
     "iam:GetLoginProfile","iam:ListAttachedUserPolicies","iam:ListAttachedRolePolicies","iam:GetRolePolicy","iam:ListUserTags","iam:ListRoleTags",
     "iam:SimulatePrincipalPolicy","ec2:DescribeInstances","ec2:DescribeNetworkInterfaces","ec2:DescribeSecurityGroups",
     "ec2:DescribeIamInstanceProfileAssociations","s3:GetBucketPublicAccessBlock","s3:GetAccountPublicAccessBlock","cloudtrail:GetTrailStatus",
     "guardduty:ListDetectors","guardduty:GetDetector","guardduty:GetFindings","securityhub:GetFindings"]},
    {"Sid":"Users","Effect":"Allow","Resource":"arn:aws:iam::*:user/*","Action":["iam:UpdateAccessKey","iam:DeleteLoginProfile","iam:TagUser","iam:UntagUser"]},
    {"Sid":"Roles","Effect":"Allow","Resource":"arn:aws:iam::*:role/*","Action":["iam:TagRole","iam:UntagRole"]},
    {"Sid":"DenyAllOnly","Effect":"Allow","Resource":"*","Action":["iam:AttachUserPolicy","iam:DetachUserPolicy","iam:AttachRolePolicy","iam:DetachRolePolicy"],
     "Condition":{"ArnEquals":{"iam:PolicyARN":["arn:aws:iam::aws:policy/AWSDenyAll","arn:aws:iam::aws:policy/AWSCompromisedKeyQuarantineV3"]}}},
    {"Sid":"Instances","Effect":"Allow","Resource":"*","Action":["ec2:CreateSecurityGroup","ec2:RevokeSecurityGroupEgress","ec2:CreateTags","ec2:DeleteTags",
     "ec2:ModifyNetworkInterfaceAttribute","ec2:DisassociateIamInstanceProfile","ec2:CreateSnapshots","ec2:StopInstances","ec2:ModifyInstanceAttribute"]},
    {"Sid":"Buckets","Effect":"Allow","Resource":"*","Action":["s3:PutBucketPublicAccessBlock","s3:PutAccountPublicAccessBlock"]},
    {"Sid":"Findings","Effect":"Allow","Resource":"*","Action":["guardduty:ArchiveFindings","guardduty:UnarchiveFindings","guardduty:UpdateFindingsFeedback",
     "guardduty:UpdateDetector","securityhub:BatchUpdateFindings","cloudtrail:StartLogging"]},
    {"Sid":"NeverIdentityCenterOrAdminRoles","Effect":"Deny","NotAction":["iam:Get*","iam:List*","iam:SimulatePrincipalPolicy"],
     "Resource":["arn:aws:iam::*:role/aws-reserved/*","arn:aws:iam::*:role/OrganizationAccountAccessRole"]}]}
   ```

2. **Only if agents should end a role's open sessions** with
   `revoke-role-sessions`, add this statement too. IAM cannot limit what an
   inline policy it allows says, so it lets the permission set give any role
   any permission; it is off unless you add it, and `quarantine-principal`
   already stops open sessions:

   ```json
   {"Sid":"RevokeSessions","Effect":"Allow","Resource":"arn:aws:iam::*:role/*","Action":["iam:PutRolePolicy","iam:DeleteRolePolicy"]}
   ```

3. **Assign it** only to a responder user or group, only in the accounts where
   containment is wanted, and not in the management account. Require MFA for
   them at your identity provider.
4. Add the account with the same portal URL and the permission set's name as
   the role, and ask an agent to run its **check-access**, which simulates each
   operation's actions against the permission set's policies and says which it
   lacks and what to add, warning when it allows far more.

What agents can do, each by the user's or role's ARN, the instance's ID, the
bucket's name, the trail's ARN or the findings' IDs, with the account:

| Action | Held for your approval | What it does |
| --- | --- | --- |
| `deactivate-access-key` | Yes | Turns off one of a user's keys, after checking it is that user's, saying its last use. It tags the user `pion-deactivated-` and the key's ID first, as Pion's mark. |
| `reactivate-access-key` | Yes | Turns a key back on, only when the user carries Pion's mark for it, and removes the mark. |
| `quarantine-principal` | Yes | Attaches AWS's `AWSDenyAll`, or `AWSCompromisedKeyQuarantineV3`, to a user or role, which also stops its open sessions and keys within seconds. It tags it `pion-quarantine` first, says when the policy was already attached by someone else, and refuses Identity Center's, AWS's and the organisation's own roles. |
| `release-principal` | Yes | Detaches the policy Pion's tag names and removes the tag; a deny-all policy someone else attached stays. |
| `revoke-role-sessions` | Yes | Denies every session of a role made before now, with an inline policy `PionRevokeOlderSessions`, as IAM's own revocation does. It refuses a policy of that name Pion did not write. Off unless the optional permission is added. |
| `remove-session-revocation` | Yes | Deletes that policy, only when it is the one Pion writes. |
| `delete-login-profile` | Yes | Removes a user's console password. It cannot be undone: a new password must be set. |
| `isolate-instance` | Yes | Makes, or reuses, a security group `pion-isolate-` and the instance's ID in its VPC, tagged `pion-isolation`, with no rules in or out, records each network interface's groups in a `pion-previous-groups` tag on it, and moves each interface into it. It changes nothing unless every interface, its groups and every rule of Pion's group can be read, and the group it makes reads back as Pion's, in the account and VPC, before any interface moves. It refuses a group of that name Pion did not make, one someone added rules to, or an interface whose record says something else, which it keeps rather than replace. It says each record and each move as it makes it, so a failure part way says exactly what was done; tried again, it uses the records already written. Connections already open may continue until they close. |
| `unisolate-instance` | Yes | Puts back the recorded groups of each interface still only in Pion's group, and removes the record, saying any record it could not remove, which trying again removes; an interface changed since is left as it is and said. Pion's empty group stays, to delete in the EC2 console. |
| `detach-instance-profile` | Yes | Takes an instance's role away, saying which profile it was. Credentials it already took stay good until they expire, so quarantine the role too. |
| `stop-instance` | Yes | Stops an instance; what is only in its memory is lost, its volumes stay. |
| `snapshot-volumes` | No | Snapshots every EBS volume of an instance at once, tagged `pion-evidence`. |
| `protect-instance` | No | Turns on an instance's termination protection. |
| `block-s3-public-access` | Yes | Turns on all four Block Public Access settings of a bucket, or the whole account, saying what they were. A bucket another account owns is refused by S3 itself, as Pion names the owner it expects. |
| `restart-logging` | No | Starts a stopped CloudTrail trail, or turns a suspended GuardDuty detector back on. |
| `archive-guardduty-findings` | Yes | Archives GuardDuty findings, after checking the account's detector holds them, which takes them out of the alert watch. |
| `unarchive-guardduty-findings` | No | Reopens archived GuardDuty findings. |
| `guardduty-feedback` | No | Tells GuardDuty whether findings were useful, which hides nothing. |
| `close-findings` | Yes | Resolves or suppresses Security Hub findings, which takes them out of the alert watch, saying which AWS did not change. |
| `set-finding-workflow` | No | Marks Security Hub findings NEW or NOTIFIED, such as to reopen them. |

Every change is sent once: AWS did nothing with a request it throttled, which
is tried again, but one it could not answer is never sent twice. IAM, EC2 and
S3's settings take no write condition, so the actions on keys, quarantines and
isolation read what they act on first and again after and say when something
changed meanwhile; none promises anything about a change someone makes at the
same moment.

**Not covered:** ending sessions of Identity Center's own roles or the
person behind them, which you do in IAM Identity Center or your identity
provider; capturing memory; network ACLs; and service control policies.
