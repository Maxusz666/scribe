#! perl -w

my ($CVS_VERSION) = q$Revision$ =~ /(\d+[\d\.]*\.\d+)/;

warn 'This is scribe.perl $Revision$ of $Date$ 
Check for newer version at http://dev.w3.org/cvsweb/~checkout~/2002/scribe/

';


# Generate minutes in HTML from a text IRC/chat Log.   
#
# Author: David Booth <dbooth@w3.org> 
# License: GPL
#
# Take a raw W3C IRC log, clean it up a bit, and put it into HTML
# to create meeting minutes.  Reads stdin, writes stdout.
# Input format and required scribing conventions are in the documentation:
# http://dev.w3.org/cvsweb/%7Echeckout%7E/2002/scribe/scribedoc.htm
# It's a good idea to pipe the output through "tidy -c".
# (See http://www.w3.org/People/Raggett/tidy/ .)
#
# CONTRIBUTIONS
# Please make improvements to this program!  Check them into CVS (or
# email them to me) and notify me by email.  Thanks!  -- DBooth
# P.S. Please try to avoid dependencies on anything that the
# user might not have installed.  I'd like the code to run on
# pretty much any minimal perl installation.  
#


######################################################################
# FEATURE WISH LIST:
#
# 0. Document ScribeNick command, to indicate the scribe nickname.  See
# http://lists.w3.org/Archives/Team/w3t-arch/2004MarApr/att-0117/minutes.html
# where Scribe was Yves but nick was ScrYves.
#
# 1 Make <scribe> statement lines look better.
#
# 1.1. Fix the default (public) format.  It currently indents the first
# line of each speaker statement, which makes subsequent lines look ragged:
#	    Hugo: He told me it's based on WSDL 1.1.
#	Who wants to champion this response? 
#	Need someone to read the spec.
#
# 2. Allow the scribe to change.  Process multiple "Scribe: dbooth" commands.
# Maybe add "Scribes: dbooth hugo" command.
# See http://cvs.w3.org/Team/~checkout~/WWW/2003/11/21-ia-irc.txt?rev=1.139&content-type=text/plain
#
# 3. Handle weird chars in nick name: <maxf``>
# See http://cvs.w3.org/Team/~checkout~/WWW/2003/11/21-ia-irc.txt?rev=1.139&content-type=text/plain
#
# 4. Improve the guess of who attended, when zakim did not report
# "attendees were ....".  Pick them up from zakim's lines like:
#	<dbooth> zakim, who is here?
#	<Zakim> On the phone I see Mike_Champion, Hugo, Dbooth, Suresh
#	<Zakim> + +1.978.235.aaaa
#	<hugo> Zakim, aaaa is Yin-Leng
#	<Zakim> +Yin-Leng; got it
#	<Zakim> +??P3
#	<Zakim> +S_Kumar
#	<Zakim> +Katia_Sycara
#	<Zakim> +Abbie
#	<Zakim> +Sinisa
#	<Zakim> +MIT308
#	<Zakim> +Sandro
#	<RalphS> zakim, mit308 has DBooth, Ralph
#	<Zakim> +DBooth, Ralph; got it
#	<RalphS> zakim, Steve just arrived in mit308
#	<Zakim> +Steve; got it
# (Examples are from http://www.w3.org/2003/12/11-ws-arch-irc.txt 
# and http://www.w3.org/2003/12/09-mit-irc.txt )
# (Also remember to watch out for zakim's continuation lines.)
#
# 5. Add a -keepUrls option to retain IRC lines that were not written
# by the scribe even when the -scribeOnly option is used.
#
# 6. Recognize [[ ...lines... ]] and treat them as a block by
# allowing them to be continuation lines for the same speaker,
# because they are probably pasted in.
#
# 7. Get $actionTemplate and $preSpeakerHTML, etc. from the HTML template,
# so that all formatting info is in the template.
#
# 8. Restructure the code to go through a big loop, processing one line
# at a time, with look-ahead to join continuation lines.
#
# 9. (From Hugo) Have RRSAgent run scribe.perl automatically when it 
# excuses itself
#
# 10. Delete extra stopList from GetNames.  (There is already a global one.)
#

######################################################################
#
# WARNING: The code is a horrible mess.  (Sorry!)  Please hold your nose if 
# you look at it.  If you have something better, or make improvements
# to this (and please do!), please let me know.  Perhaps it's a good 
# example of Fred Brooke's advice in Mythical Man Month: "Plan to throw 
# one away". 
#
######################################################################


# Formatting:
# my $preSpeakerHTML = "<strong>";
# my $postSpeakerHTML = "</strong> <br />";
my $preSpeakerHTML = "<cite class='phone'>";
my $postSpeakerHTML = "</cite>";
my $preIRCSpeakerHTML = "<cite class='irc'>";
my $postIRCSpeakerHTML = "</cite>";
my $prePhoneParagraphHTML = "<p class='phone'>";
my $postPhoneParagraphHTML = "</p>";
my $preIRCParagraphHTML = "<p class='irc'>";
my $postIRCParagraphHTML = "</p>";

my $preTopicHTML = "<h3";
my $postTopicHTML = "</h3>";

# Other globals
my $debug = 0;
my $debugActions = 0;
my $namePattern = '([\\w]([\\w\\d\\-\\.]*))';
# warn "namePattern: $namePattern\n";

# These are the recognized commands.  Each command should be a
# single word, so use underscores if you have a multi-word command.
my @ucCommands = qw(Meeting Scribe ScribeNick Topic Chair 
	Present Regrets Agenda 
	IRC Log IRC_Log IRCLog Previous_Meeting PreviousMeeting ACTION);
# Make lower case and generate spelling variations
@commands = &Uniq(&WordVariations(map {&LC($_)} @ucCommands));
# Map to preferred spelling:
my %commands = &WordVariationsMap(@ucCommands);
# A pattern to match any of them.  (Be sure to use case-insensitive matching.)
my $commandsPattern = &MakePattern(keys %commands);
# warn "commandsPattern: $commandsPattern\n";

# These are the recognized action statuses.  Each status should be a
# single word, so use underscores if you have a multi-word status.
# See also http://www.w3.org/2001/sw/Europe/200401/actions/
# Note that these are ordered: The order in which they are listed here
# will be the order in which they are listed in the resulting minutes.
# Status words that are on the same line below are treated as synonyms.
# The first word of each subgroup is treated as the preferred spelling
# for that subgroup.
my @ucActionStatusListReferences = 
	(
        [qw( NEW )],
        [qw( PENDING IN_PROGRESS IN_PROCESS NO_PROGRESS NEEDS_ACTION ONGOING )],
        [qw( UNKNOWN )],
        [qw( DONE COMPLETED FINISHED )],
        [qw( DROPPED RETIRED CANCELLED CANCELED WITHDRAWN )],
	);
# Flatten the list:
my @ucActionStatuses = map { @{$_} } @ucActionStatusListReferences;

my @actionStatuses = &Uniq(&WordVariations(map {&LC($_)} @ucActionStatuses));
my %actionStatuses = (); # Map to preferred spelling. Keys are lower case.
foreach my $statusRef ( @ucActionStatusListReferences )
	{
	my @statuses = @{$statusRef};
	next if !@statuses;
	# Map other spellings to preferred spelling:
	my $pref = $statuses[0];
	foreach my $other (&Uniq(&WordVariations(map {&LC($_)} @statuses)))
		{
		$actionStatuses{$other} = $pref;
		}
	}

foreach my $sk (sort keys %actionStatuses)
	{
	my $v = $actionStatuses{$sk};
	warn "actionStatuses map: $sk --> $v\n" if $debugActions;
	}

# A pattern to match any of them.  (Be sure to use case-insensitive matching.)
my $actionStatusesPattern = &MakePattern(keys %actionStatuses);

my @rooms = qw(MIT308 SophiaSofa DISA Fujitsu);

# stopList are non-people.
my @stopList = qw(a q on Re items Zakim Topic muted and agenda Regrets http the
	RRSAgent Loggy Zakim2 ACTION Chair Meeting DONE PENDING WITHDRAWN
	Scribe 00AM 00PM P IRC Topics Keio DROPPED ger-logger
	yes no abstain Consensus Participants Question RESOLVED strategy
	AGREED Date queue no one in XachBot got it WARNING upcoming);
# @stopList = (@stopList, @rooms);
@stopList = (@stopList, @commands, @actionStatuses);
@stopList = &Uniq(&WordVariations(map {&LC($_)} @stopList));
# Use a hash to quickly determine whether a word is in the list.
my %stopList = &WordVariationsMap(@stopList);
# A pattern to match any of them.  (Be sure to use case-insensitive matching.)
my $stopListPattern = &MakePattern(keys %stopList);

# Globals
my $all = "";			# Input.  
my $template = &DefaultTemplate();	# Template for minutes
my $bestName = "";  		# Name of input format normalizer guessed

# Get options/args
my $normalizeOnly = 0;		# Output only the normlized input
my $canonicalizeNames = 0;	# Convert all names to their canonical form?
my $scribeOnly = 0;		# Only select scribe lines
my $trustRRSAgent = 0;		# Trust RRSAgent?
my $breakActions = 1;		# Break long action lines?
my $implicitContinuations = 0;	# Option: -implicitContinuations
my $scribeName = ""; 		# Example: -scribe dbooth
				# Or: -scribe "David_Booth"
my $scribeNick = "";	 	# Example: -scribeNick dbooth
my $useZakimTopics = 1; 	# Treat zakim agenda take-up as Topic change?
my $inputFormat = "";		# Input format, e.g., Plain_Text_Format
my $minScribeLines = 40;	# Min lines to be guessed as scribe.
my $dashTopics = 0;		# Treat "---" as starting a new topic
my $runTidy = 0;		# Pipe the output through "tidy -c"
my $preferredContinuation = "..."; # Either "... " or " ".
my $embeddedScribeOptions = "";	# Any "ScribeOptions: ..." from input

# Loop to get options and input.  The reason this is a loop is that there
# may be options embedded in the input (using "ScribeOptions: ...").
# In which case, we need to restart using those as default options.
my @SAVE_ARGV = @ARGV;
my $restartForEmbeddedOptions = 1;
while($restartForEmbeddedOptions)
	{
	$restartForEmbeddedOptions = 0;

	@ARGV = @SAVE_ARGV;
	my @args = ();
	$template = &DefaultTemplate();
	my $scribeDefaultOptions = 'SCRIBEOPTIONS';
	if ($embeddedScribeOptions) {
		# Put embedded options at front of list for lower priority
		@ARGV = (split(' ', $embeddedScribeOptions), @ARGV);
	}
	if ($ENV{$scribeDefaultOptions}) {
		# Put env options at front of list for lowest priority
		@ARGV = (split(' ', $ENV{$scribeDefaultOptions}), @ARGV);
	}
	while (@ARGV)
		{
		my $a = shift @ARGV;
		if (0) {}
		elsif ($a eq "") 
			{ }
		elsif ($a eq "-normalize") 
			{ $normalizeOnly = 1; }
		elsif ($a eq "-sampleInput") 
			{ print STDOUT &SampleInput(); exit 0; }
		elsif ($a eq "-sampleOutput") 
			{ 
			warn "\nWARNING: Replacing input because of -sampleOutput option\n\n" if $all;
			$all = &SampleInput(); 
			}
		elsif ($a eq "-sampleTemplate") 
			{ print STDOUT &DefaultTemplate(); exit 0; }
		elsif ($a eq "-scribeOnly") 
			{ $scribeOnly = 1; }
		elsif ($a eq "-canon") 
			{ $canonicalizeNames = 1; }
		elsif ($a eq "-noBreakActions") 
			{ $breakActions = 0; }
		elsif ($a eq "-breakActions") 
			{ $breakActions = 1; }
		elsif ($a eq "-noTrustRRSAgent") 
			{ $trustRRSAgent = 0; }
		elsif ($a eq "-trustRRSAgent") 
			{ $trustRRSAgent = 1; }
		elsif ($a eq "-teamSynonyms") 
			{ warn "\nWARNING: -teamSynonyms option no longer implemented\n\n"; }
		elsif ($a eq "-mit") 
			{ $template = &MITTemplate(); }
		elsif ($a eq "-team") 
			{ $template = &TeamTemplate(); }
		elsif ($a eq "-member") 
			{ $template = &MemberTemplate(); }
		elsif ($a eq "-world") 
			{ $template = &PublicTemplate(); }
		elsif ($a eq "-public") 
			{ $template = &PublicTemplate(); }
		elsif ($a eq "-template") 
			{ 
			my $templateFile = shift @ARGV; 
			die "ERROR: Template file not found: $templateFile\n"
				if !-e $templateFile;
			my $t = &GetTemplate($templateFile);
			if (!$t)
				{
				die "ERROR: Empty template: $templateFile\n";
				}
			$template = $t;
			}
		elsif ($a eq "-debug") 
			{ $debug = 1; }
		elsif ($a eq "-noUseZakimTopics" || $a eq "-noZakimTopics") 
			{ $useZakimTopics = 0; }
		elsif ($a eq "-useZakimTopics" || $a eq "-zakimTopics") 
			{ $useZakimTopics = 1; }
		elsif ($a eq "-implicitContinuations"
			|| $a eq "implicitContinuation") 
			{ $implicitContinuations = 1; }
		elsif ($a eq "-minScribeLines") 
			{ $minScribeLines = shift @ARGV; }
		elsif ($a eq "-inputFormat") 
			{ $inputFormat = shift @ARGV; }
		elsif ($a eq "-dashTopics" || $a eq "-philippe" || $a eq "-plh") 
			{ $dashTopics = 1; }
		elsif ($a eq "-noDashTopics" || $a eq "-noPhilippe" || $a eq "-noPlh") 
			{ $dashTopics = 0; }
		elsif ($a eq "-scribe" || $a eq "-scribeName") 
			{ $scribeName = shift @ARGV; }
		elsif ($a eq "-scribeNick" || $a eq "-scribeNickname") 
			{ $scribeNick = shift @ARGV; }
		elsif ($a eq "-tidy") 
			{ 
			open(STDOUT, "| tidy -c") || die "ERROR: Could not run \"tidy -c\"\nYou need to have tidy installed on your system to use\nthe -tidy option.\n";
			}
		elsif ($a eq "-help" || $a eq "-h") 
			{ die "For help, see http://dev.w3.org/cvsweb/%7Echeckout%7E/2002/scribe/scribedoc.htm\n"; }
		elsif ($a =~ m/\A\-/)
			{ 
			warn "ERROR: Unknown option: $a\n"; 
			die "For help, see http://dev.w3.org/cvsweb/%7Echeckout%7E/2002/scribe/scribedoc.htm\n"; 
			}
		else	
			{ push(@args, $a); }
		}
	@ARGV = @args;
	@ARGV = map {glob} @ARGV;	# Expand wildcards in arguments

	# Get input:
	$all =  join("",<>) if !$all;
	if (!$all)
		{
		warn "\nWARNING: Empty input.\n\n";
		}
	# Delete control-M's if any.  Cygwin seems to add them. :(
	$all =~ s/\r//g;

	# Normalize input format.  This accepts several formats of input
	# and puts it into a common format.
	# The @inputFormats is the list of known normalizer functions.
	# Each one is defined below.
	# Just add another to the list if you want to recognize another format.
	# Each function takes $all (the input text) as input and returns
	# a pair: ($score, $newAll). 
	#	$score is a value [0,1] indicating how well it matched (fraction
	#		of lines conforming to this format).
	#	$newAll is the normalized input.
	my @inputFormats = qw(
			RRSAgent_Text_Format 
			RRSAgent_HTML_Format 
			RRSAgent_Visible_HTML_Text_Paste_Format
			Mirc_Text_Format
			Irssi_ISO8601_Log_Text_Format
			Yahoo_IM_Format
			Plain_Text_Format
			Normalized_Format
			);
	my %inputFormats = map {($_,$_)} @inputFormats;
	if ($inputFormat && !exists($inputFormats{$inputFormat}))
		{
		warn "\nWARNING: Unknown input format specified: $inputFormat\n";
		warn "Reverting to guessing the format.\n\n";
		$inputFormat = "";
		}
	# Try each known format, and see which one matches best.
	my $bestScore = 0;
	my $bestAll = "";
	$bestName = "";  	# Global var because we access it later
	foreach my $f (@inputFormats)
		{
		my ($score, $newAll) = &$f($all);
		# warn "$f: $score\n";
		if ($score > $bestScore)
			{
			$bestScore = $score;
			$bestAll = $newAll;
			$bestName = $f;
			}
		}
	my $bestScoreString = sprintf("%4.2f", $bestScore);
	if ($inputFormat)
		{
		# warn "INPUT FORMAT: $inputFormat\n";
		# Format was specified using -inputFormat option
		my ($score, $newAll) = &$inputFormat($all);
		my $scoreString = sprintf("%4.2f", $score);
		$all = $newAll;
		warn "\nWARNING: Input looks more like $bestName format (score $bestScoreString),
	but \"-inputFormat $inputFormat\" (score $scoreString) was specified.\n\n"
			if $score < $bestScore;
		}
	else	{
		warn "Guessing input format: $bestName (score $bestScoreString)\n\n";
		die "ERROR: Could not guess input format.\n" if $bestScore == 0;
		warn "\nWARNING: Low confidence ($bestScoreString) on guessing input format: $bestName\n\n"
			if $bestScore < 0.7;
		$all = $bestAll;
		}

	# Perform s/old/new/ substitutions.
	# 5/11/04: dbooth changed this to be first to last, because that's
	# what user's expect.
	while($all =~ m/\A((.|\n)*?)(\n\<[^\>]+\>\s*s\/([^\/]+)\/([^\/]*?)((\/(g))|\/?)(\s*)\n)/i)
		{
		my $old = $4;
		my $new = $5;
		my $global = $8;
		$global = "" if !defined($global);
		my $pre = $1;
		my $match = $3;
		my $post = $';
		my $oldp = quotemeta($old);
		# warn "Found match: $match\n";
		my $told = $old;
		$told = $& . "...(truncated)...." if ($old =~ m/\A.*\n/);
		my $tnew = $new;
		$tnew = $& . "...(truncated)...." if ($old =~ m/\A.*\n/);
		my $succeeded = 0;
		my $tall = $pre . "\n" . $post;
		# s/old/new/g  replaces globally from this point backward
		if (($global eq "g")  && $pre =~ s/$oldp/$new/g)
			{
			warn "Succeeded: s/$told/$tnew/$global\n";
			$all = $pre . "\n" . $post;
			}
		# s/old/new/G  replaces globally, both forward and backward
		elsif (($global eq "G")  && $tall =~ s/$oldp/$new/g)
			{ 
			warn "Succeeded: s/$told/$tnew/$global\n";
			$all = $tall;
			}
		# s/old/new/  replaces most recent occurrance of old with new
		elsif ((!$global) && $pre =~ s/\A((.|\n)*)($oldp)((.|\n)*?)\Z/$1$new$4/)
			{
			warn "Succeeded: s/$told/$tnew/$global\n";
			$all = $pre . "\n" . $post;
			}
		else	{
			warn "\nWARNING: FAILED: s/$told/$tnew/$global\n\n";
			$match = &Trim($match);
			$all = $pre . "\n[scribe.perl auto substitution failed:] " . $match . "\n" . $post;
			}
		warn "\nWARNING: Multiline substitution!!! (Is this correct?)\n\n" if $tnew ne $new || $told ne $old;
		}
	# Look for embedded options, and restart if we find some.
	# (Except we do NOT re-read the input.  We keep $all as is.)
	while ($all =~ s/\n\<[^\<\>]+\>\s*ScribeOption(s?)\s*\:(.*)\n/\n/i)
		{
		my $newOptions = &Trim($2);
		$embeddedScribeOptions .= " $newOptions";
		# warn "FOUND new ScribeOptions: $newOptions\n";
		$restartForEmbeddedOptions = 1;
		}
	if ($restartForEmbeddedOptions)
		{
		warn "FOUND embedded ScribeOptions: $embeddedScribeOptions\n*** RESTARTING DUE TO EMBEDDED OPTIONS ***\n\n";
		# Prevent input from being re-normalized:
		push(@SAVE_ARGV, ("-inputFormat", "Normalized_Format"));
		}
	}

if ($canonicalizeNames) 
	{
	# Strip -home from names.  (Convert alan-home to alan, for example.)
	$all =~ s/(\w+)\-home\b/$1/ig;
	# Strip -lap from names.  (Convert alan-lap to alan, for example.)
	$all =~ s/(\w+)\-lap\b/$1/ig;
	# Strip -iMac from names.  (Convert alan-iMac to alan, for example.)
	$all =~ s/(\w+)\-iMac\b/$1/ig;
	}

if ($useZakimTopics)
	{
	# Treat zakim statements like:
	#	<Zakim> agendum 2. "UTF16 PR issue" taken up [from MSMscribe]
	# as equivalent to:
	#	<scribe> Topic: UTF16 PR issue
	$all = "\n$all\n";
	while ($all =~ s/\n\<Zakim\>\s*agendum\s*\d+\.\s*\"(.+)\"\s*taken up\s*((\[from (.*?)\])?)\s*\n/\n\<scribe\> Topic\: $1\n/i)
		{
		# warn "Zakim Topic: $1\n";
		}
	}

# See if the $dashTopics option should be used.  That option causes
# dash lines to indicate the start of a new topic, such as:
#	<plh> ---
#	<plh> Move to Stata Center
#	<plh> Alan: What is the status of the Stata move?
# which will be converted to the following if $dashTopics is used: 
#	<plh> Topic: Move to Stata Center
#	<plh> Alan: What is the status of the Stata move?
# First see how many "Topic:" lines we have:
my @topicLines = grep 
	{
	my ($writer, $type, $value, $rest, undef) = &ParseLine($_);
	$type eq "COMMAND" && &LC($value) eq "topic" && $rest ne "";
	} split(/\n/, $all);
# Now see how many we'd get if we used the $dashTopics option:
my ($allDashTopics, $nDashTopics) = &ConvertDashTopics($all);
# Now decide what to do.  There are three variables, which we can treat
# as booleans (0 or non-0) for the purpose of covering all cases:
#	$dashTopics
#	$nDashTopics
#	@topicLines
# For completeness, we'll just enumerate the 8 cases:
if (0) {}
elsif ((!$dashTopics) && (!$nDashTopics) && (!@topicLines))
	{ warn "\nWARNING: No \"Topic:\" lines found.\n\n"; }
elsif ((!$dashTopics) && (!$nDashTopics) && ( @topicLines))
	{ }
elsif ((!$dashTopics) && ( $nDashTopics) && (!@topicLines))
	{ 
	warn "\nWARNING: No \"Topic:\" lines found, but dash separators were found.  \nDefaulting to -dashTopics option.\n\n"; 
	$dashTopics = 1;
	}
elsif ((!$dashTopics) && ( $nDashTopics) && ( @topicLines))
	{ 
	warn "\nWARNING: Dash separator lines found.  If you intended them to mark\nthe start of a new topic, you need the -dashTopics option.\nFor example:\n        <Philippe> ---\n        <Philippe> Review of Action Items\n\n";
	}
elsif (( $dashTopics) && (!$nDashTopics) && (!@topicLines))
	{ warn "\nWARNING: No \"Topic:\" lines found.\n\n"; }
elsif (( $dashTopics) && (!$nDashTopics) && ( @topicLines))
	{ 
	warn "\nWARNING: -dashTopics option used, but no separator lines found.\nFor example:\n        <Philippe> ---\n        <Philippe> Review of Action Items\n\n";
	}
elsif (( $dashTopics) && ( $nDashTopics) && (!@topicLines))
	{ }
elsif (( $dashTopics) && ( $nDashTopics) && ( @topicLines))
	{ }
else { die "Internal logic error "; }
# Finally, apply the $dashTopics option if enabled.
if ($dashTopics)
	{
	$all = $allDashTopics;
	}

# Remove duplicate Topic lines
if (1)
	{
	my @lines = split(/\n/, $all);
	my @nonredundantlines = ();
	my $previousTopic = "";
	foreach my $line (@lines)
		{
		my $ignore = 0;
		my ($writer, $type, $value, $rest, undef) = &ParseLine($line);
		if ($type eq "COMMAND" && &LC($value) eq "topic")
			{
			$ignore = 1 if (&LC($rest) eq &LC($previousTopic));
			$previousTopic = $rest;
			}
		push(@nonredundantLines, $line) if !$ignore;
		}
	$all = "\n" . join("\n", @nonredundantLines) . "\n";
	}

if ($normalizeOnly)
	{
	# This isn't really very good.  I thought this would be a
	# useful option, but now I'm not so sure, because several
	# of the scribe.perl commands (such as "Scribe: ...") are
	# removed when they're processed.
	my $t = join("\n", grep {m/\A\</;} split(/\n/, $all)) . "\n";
	print "$t\n";
	exit 0;
	}

# Get attendee list, and canonicalize names within the document:
my @uniqNames = ();
my $allNameRefsRef;
($all, $allNameRefsRef, @uniqNames) = &GetNames($all);
my @allNames = map { ${$_} } @{$allNameRefsRef};

# Determine scribe name and scribeNick:
$scribeName = $1 if $all =~ s/\n\<[^\>\ ]+\>\s*Scribe\s*\:\s*(.+?)\s*\n/\n/i;
$scribeNick = $1 if $all =~ s/\n\<[^\>\ ]+\>\s*Scribe[ _\-]?Nick\s*\:\s*(.+?)\s*\n/\n/i;
$scribeName = &Trim($scribeName);
$scribeNick = &Trim($scribeNick);
($scribeName, $scribeNick, $all) = 
	&SetScribeNameAndNick($scribeName, $scribeNick, $all);
warn "Scribe: $scribeName\n";
warn "ScribeNick: $scribeNick\n";

push(@allNames,"scribe");
my @allSpeakerPatterns = map {quotemeta($_)} @allNames;
my $speakerPattern = "((" . join(")|(", @allSpeakerPatterns) . "))";
# warn "speakerPattern: $speakerPattern\n";

# Get the list of people present.
# First look for zakim output, as the default:
my @present = &GetPresentFromZakim($all); 
warn "Default Present: " . join(", ", @present) . "\n" if @present;
# Now look for explicit "Present: ... " commands:
die if !defined($all);
($all, @present) = &GetPresentOrRegrets("Present", 3, $all, @present); 
die if !defined($all);

# Get the list of regrets:
my @regrets = ();	# People who sent regrets
($all, @regrets) = &GetPresentOrRegrets("Regrets", 0, $all, ()); 

# Grab meeting name:
my $title = "SV_MEETING_TITLE";
if ($all =~ s/\n\<$namePattern\>\s*(Meeting)\s*\:\s*(.*)\n/\n/i)
	{ $title = $4; }
else 	{ 
	warn "\nWARNING: No meeting title found!
You should specify the meeting title like this:
<dbooth> Meeting: Weekly Baking Club Meeting\n\n";
	}

# Grab agenda URL:
my $agendaLocation;
if ($all =~ s/\n\<$namePattern\>\s*(Agenda)\s*\:\s*(http:\/\/\S+)\n/\n/i)
	{ $agendaLocation = $4;
	  warn "Agenda: $agendaLocation\n";
      }
else 	{ 
	warn "\nWARNING: No agenda location found (optional).
If you wish, you may specify the agenda like this:
<dbooth> Agenda: http://www.example.com/agenda.html\n\n";
	}

# Grab Previous meeting URL:
my $previousURL = "SV_PREVIOUS_MEETING_URL";
if ($all =~ s/\n\<$namePattern\>\s*(Previous[ _\-]*Meeting)\s*\:\s*(.*)\n/\n/i)
	{ $previousURL = $4; }

# Grab Chair:
my $chair = "SV_MEETING_CHAIR";
if ($all =~ s/\n\<$namePattern\>\s*(Chair(s?))\s*\:\s*(.*)\n/\n/i)
	{ $chair = $5; }
else 	{ 
	warn "\nWARNING: No meeting chair found!
You should specify the meeting chair like this:
<dbooth> Chair: dbooth\n\n";
	}

# Grab IRC Log URL.  Do this before looking for the date, because
# we can figure out the date from the IRC log name.
my $logURL = "SV_MEETING_IRC_URL";
# <RRSAgent>   recorded in http://www.w3.org/2002/04/05-arch-irc#T15-46-50
$logURL = $3 if $all =~ m/\n\<(RRSAgent|Zakim)\>\s*(recorded|logged)\s+in\s+(http\:([^\s\#]+))/i;
$logURL = $3 if $all =~ m/\n\<(RRSAgent|Zakim)\>\s*(see|recorded\s+in)\s+(http\:([^\s\#]+))/i;
$logURL = $6 if $all =~ s/\n\<$namePattern\>\s*(IRC|Log|(IRC([\s_]*)Log))\s*\:\s*(.*)\n/\n/i;

# Grab and remove date from $all
my ($day0, $mon0, $year, $monthAlpha) = &GetDate($all, $namePattern, $logURL);

######### ACTION Item Processing
# First put all action items into a common format, to make them easier to process.
my @lines = split(/\n/, $all);
my %debugTypesSeen = ();
for (my $i=0; $i<(@lines-1); $i++)
	{
	# First move the status out from in front of ACTION,
	# so that ACTION is always at the beginning.
	# Convert lines like: 
	#	[PENDING] ACTION: whatever
	# into lines like:
	#	ACTION: [PENDING] whatever
	if (1)
		{
		my ($writer, $type, $value, $rest, undef) = &ParseLine($lines[$i]);
		my ($writer2, $type2, $value2, $rest2, undef) = &ParseLine("<scribe> $rest");
		while ($type2 eq "STATUS")
			{
			# Ignore nested status:
			#	[PENDING] [NEW] ACTION: whatever
			($writer2, $type2, $value2, $rest2, undef) = &ParseLine("<scribe> $rest2");
			}
		$debugTypesSeen{$type}++;
		warn "LINETYPE writer: $writer type: $type value: $value rest: $rest\n" if $debugActions && $debugTypesSeen{$type} < 3;
		if ($type eq "STATUS" && $type2 eq "COMMAND" && &LC($value2) eq "action")
			{
			$lines[$i] = "<$writer\> ACTION: \[$value\] $rest2";
			warn "MOVED: $lines[$i]\n" if $debugActions;
			}
		}

	if (1)
		{
		# Now join ACTION continuation lines.  Convert lines like:
		#	<dbooth> ACTION: Mary to buy
		#	<dbooth>   the ingredients.
		# to this:
		#	<dbooth> ACTION: Mary to buy the ingredients.
		# It might be better if the continuation line processing was
		# done only once, globally, instead of doing it separately here
		# for actions.
		my ($writer, $type, $value, $rest, undef) = &ParseLine($lines[$i]);
		my ($writer2, $type2, $value2, $rest2, undef) = &ParseLine($lines[$i+1]);
		$debugTypesSeen{$type}++;
		warn "LINETYPE writer: $writer type: $type value: $value rest: $rest\n" if $debugActions && $debugTypesSeen{$type} < 3;
		if ($type eq "COMMAND" && &LC($value) eq "action"
			&& &LC($writer2) eq &LC($writer)
			&& ($type2 eq "CONTINUATION"))
			{
			$lines[$i] = "";
			$lines[$i+1] = "<$writer\> ACTION: $rest $rest2";
			warn "JOINED ACTION CONTINUATION: " . $lines[$i+1] . "\n" if $debugActions;
			}
		#### Commented out this branch, since I think it is handled
		#### below anyway.
		elsif (0 && $type eq "COMMAND" && &LC($value) eq "action"
			&& &LC($writer2) eq &LC($writer)
			&& ($type2 eq "STATUS"))
			{
			my $cont = "\[$value2\] $rest2"; 
			$lines[$i] = "";
			$lines[$i+1] = "<$writer\> ACTION: $rest $cont";
			warn "JOINED: " . $lines[$i+1] . "\n" if $debugActions;
			}

		}

	if (1)
		{
		# Now look for status on lines following ACTION lines.
		# This only works if we are NOT using RRSAgent's recorded actions.
		# Join line pairs like this:
		#	<dbooth> ACTION: whatever
		#	<dbooth> *DONE*
		# to lines like this:
		#	<dbooth> ACTION: whatever [DONE]
		my ($writer, $type, $value, $rest, undef) = &ParseLine($lines[$i]);
		if ($type eq "COMMAND" && &LC($value) eq "action" && $i+1<@lines)
			{
			# warn "FOUND ACTION: $rest\n";
			# Look ahead at the next line (by anyone).
			my ($writer2, $type2, $value2, $rest2, undef) = &ParseLine($lines[$i+1]);
			if ($type2 eq "STATUS" && $rest2 eq "")
				{
				$lines[$i] = "<$writer\> ACTION: $rest \[$value2\]";
				$lines[$i+1] = "";
				warn "JOINED NEXT SPEAKER LINE: " . $lines[$i+1] . "\n" if $debugActions;
				}
			else
				{
				# Didn't find status on next line. 
				# Look ahead at the next line by the same writer.
				for (my $j=$i+2; $j<@lines; $j++)
					{
					my ($writer2, $type2, $value2, $rest2, undef) = &ParseLine($lines[$j]);
					last if ($type eq "COMMAND" && &LC($value) eq "action");
					if (&LC($writer2) eq &LC($writer))
						{
						if ($type2 eq "STATUS" && $rest2 eq "")
							{
							$lines[$i] = "<$writer\> ACTION: $rest \[$value2\]";
							$lines[$j] = "";
							warn "JOINED NEXT SPEAKER LINE: " . $lines[$i+1] . "\n" if $debugActions;
							}
						last;
						}
					}
				}
			}
		}

	if (1)
		{
		# Now grab the URL where the action was recorded.
		# Join line pairs like this:
		# 	<RRSAgent> ACTION: Simon develop ssh2 migration plan [1]
		# 	<RRSAgent>   recorded in http://www.w3.org/2003/09/02-mit-irc#T14-10-24
		# to lines like this:
		# 	<RRSAgent> ACTION: Simon develop ssh2 migration plan [1] [recorded in http://www.w3.org/2003/09/02-mit-irc#T14-10-24]
		my ($writer, $type, $value, $rest, undef) = &ParseLine($lines[$i]);
		my ($writer2, $type2, $value2, $rest2, undef) = &ParseLine($lines[$i+1]);
		if ($type eq "COMMAND" && &LC($value) eq "action"
			&& &LC($writer) eq "rrsagent" && 
			&LC($writer2) eq &LC($writer)
			&& $rest2 =~ m/\A\W*(recorded in http\:[^\s\[\]]+)(\s*\W*)\Z/i)
			{
			my $recorded = $1;
			$lines[$i] = "";
			$lines[$i+1] = "<$writer\> ACTION: $rest \[$recorded\]";
			warn "JOINED RECORDED: " . $lines[$i+1] . "\n" if $debugActions;
			}
		}
	}
$all = "\n" . join("\n", grep {$_} @lines) . "\n";

# Now it's time to collect the action items.
# Grab the action items both ways (from RRSAgent, and not from RRSAgent),
# so that we can generate a warning if we find them one way but not the other.
# We are initially sloppy about the action text we collect, because we
# will later clean it up and parse out the status and URL.
#
# First grab RRSAgent actions.
my %rrsagentActions = ();	# Actions according to RRSAgent
my @rrsagentLines = grep {m/^\<RRSAgent\>/} split(/\s*\n/, $all);
for (my $i = 0; $i <= $#rrsagentLines; $i++) {
	$_ = $rrsagentLines[$i];
	# <RRSAgent> I see 3 open action items:
	if (m/^\<RRSAgent\> I see \d+ open action items\:$/) {
	    # Start again
	    %rrsagentActions = ();
	    next;
	}
	# <RRSAgent> ACTION: Simon develop ssh2 migration plan [1]
	next unless (m/\<RRSAgent\> ACTION\: (.*)$/);
	my $action = "$1";
	$rrsagentActions{$action} = "";	# Unknown status (will default to NEW)
	warn "RRSAgent ACTION: $action\n" if $debugActions;
}

# Now grab actions the old way (not the RRSAgent lines).
my %otherActions = ();		# Actions found in text (not according to RRSAgent)
foreach my $line (split(/\n/,  $all))
	{
	next if $line =~ m/^\<RRSAgent\>/i;
	next if $line !~ m/\A\<[^\>]+\>\s*ACTION\s*\:\s*(.*?)\s*\Z/i;
	my $action = $1;
	warn "OTHER ACTION: $action\n" if $debugActions;
	$otherActions{$action} = "";
	}

# Which set of actions should we keep?
my %rawActions = ();	# Maps action to status (NEW|DONE|PENDING...)
if ($trustRRSAgent) {
	if (((keys %rrsagentActions) == 0) && ((keys %otherActions) > 0)) 
		{ warn "\nWARNING: No RRSAgent-recorded actions found, but 'ACTION:'s appear in the text.\nSUGGESTED REMEDY: Try running WITHOUT the -trustRRSAgent option\n\n"; }
	%rawActions = %rrsagentActions;
	warn "Using RRSAgent ACTIONS\n" if $debugActions;
} else {
	%rawActions = %otherActions;
	warn "Using OTHER ACTIONS\n" if $debugActions;
}

my %statusPatterns = ();	# Maps from a status to its regex.
foreach my $s (@actionStatuses)
	{
	die if $s !~ m/[a-zA-Z\_]/; # Canonical status, only letters/underscore
	my $p = quotemeta($s);
	# For multi-word status,
	# allow the user to write space or dash instead of underscore.
	# Accept as equivalent: IN_PROGRESS, IN PROGRESS, IN-PROGRESS 
	$p =~ s/\_/\[\\-\\_\\s\]\+/g; # Make _ into a pattern: [\_\-\s]+
	# warn "s: $s p: $p\n";
	$statusPatterns{$s} = $p;
	}

# Now clean up each action item and parse out its status and URL.
my %actions = ();
warn "Cleaning up each action and parsing status and URL...\n" if $debugActions;
foreach my $action ((keys %rawActions))
	{
	my $a = $action;
	next if !$a;
	my $status = "";
	my $url = "";
	my $olda = "";
	# Grab stuff off the ends as long as there is stuff to grab.
	# We do this in a loop to allow them to appear in any order.
	# However, we process them in a particular order within this
	# loop to give precedence to the status that the scribe wrote last,
	# but precedence to the URL that was recorded first.
	CHANGE: while ($a ne $olda)
		{
		warn "OLD a: $olda\n" if $debugActions;
		warn "NEW a: $a\n\n" if $debugActions;
		$olda = $a;
		$a = &Trim($a);
		next CHANGE if $a =~ s/\s*\[\d+\]?\s*\Z//;	# Delete action numbers: [4] [4
		next CHANGE if $a =~ s/\AACTION\s*\:\s*//i;	# Delete extra ACTION:
		# Grab URL from end of action.   
		# Innermost URL takes precedence if specified more than once.
		# This is not precisely the official URI pattern.
		my $urlp = "http\:[\#\%\&\*\+\,\-\.\/0-9\:\;\=\?\@-Z_a-z]+";
		if ($a =~ s/\s*\[?\s*recorded in ($urlp)\s*(\]?\s*)\Z//i)
			{
			$url = $1;
			warn "CLEANING ACTIONS GOT URL: $url\n" if $debugActions;
			next CHANGE;
			}
		foreach my $s (@actionStatuses)
			{
			my $p = $statusPatterns{$s};
			# Grab status from end of action.
			# Outermost status takes precedence if 
			# status appears more than once.
			# Note that this may whack off the right bracket
			# From the action number:
			# 	OLD a: Hugo inprog3 action [4] -- IN PROGRESS
			# 	NEW a: Hugo inprog3 action [4
			if ($a =~ s/[\*\(\[\-\=\s\:\;]+($p)[\*\)\]\-\=\s]*\Z//i)
				{
				$status = $s if !$status;
				warn "status: $status\n" if $debugActions;
				next CHANGE;
				}
			}
		foreach my $s (@actionStatuses)
			{
			my $p = $statusPatterns{$s};
			# Grab status from beginning of action.
			if ($a =~ s/\A[\*\(\[\-\=\s]*($p)[\*\)\]\-\=\s\:\;]+//i)
				{
				$status = $s if !$status;
				warn "status: $status\n" if $debugActions;
				next CHANGE;
				}
			}
		}
	# Put the URL back on the end
	$a .= " [recorded in $url]" if $url;
	$status = "NEW" if !$status;
	# Canonicalize action statuses:
	die if !exists($actionStatuses{&LC($status)});
	$status = $actionStatuses{&LC($status)}; # Map to preferred spelling
	warn "FINAL: [$status] $a\n\n" if $debugActions;
	$actions{$a} = $status;
	}

# Get a list of people who have current action items:
my %actionPeople = ();
warn "Getting list of action people...\n" if $debugActions;
foreach my $key ((keys %actions))
	{
	my $a = &LC($key);
	warn "action:$a:\n" if $debugActions;
	# Skip completed action items.  Check the status.
	die if !exists($actions{$key});
	my $lcs = &LC($actions{$key});
	my %completedStatuses = map {($_,$_)} 
		qw(done finished dropped completed retired deleted);
	next if exists($completedStatuses{$lcs});
	# Remove leading date:
	#	ACTION: 2003-10-09: Bijan to look into message extensibility Issues
	#	ACTION: 10/09/03: Bijan to look into message extensibility Issues
	#	ACTION: 10/9: Bijan to look into message extensibility Issues
	$a =~ s/\A\d+[\-\/]\d+(([\-\/]\d+)?)\s*\:\s*//;
	# Look for action recipients
	my @names = ();
	my @good = ();
	if ($a =~ m/\s+(to)\s+/i)
		{
		my $list = $`;
		@names = grep {$_ ne "and"} split(/[^a-zA-Z0-9\-\_\.]+/, $list);
		# warn "names: @names\n";
		foreach my $n (@names)
			{
			next if $n eq "";
			$n = &LC($n);
			push(@good, $n) if !exists($stopList{$n});
			}
		@good = () if @good != @names; # Fail
		}
	if ((!@good) && $a =~ m/\A([a-zA-Z0-9\-\_\.]+)/)
		{
		my $n = $1;
		@names = ($n);
		push(@good, $n) if !exists($stopList{$n});
		}
	# All good?
	if (@good && @good == @names)
		{
		foreach my $n (@good)
			{
			$actionPeople{$n} = $n;
			}
		}
	else	{
		warn "NO PERSON FOUND FOR ACTION: $a\n";
		}
	}
warn "People with action items: ",join(" ", sort keys %actionPeople), "\n";

# Format the resulting action items.
# Iterate through the @actionStatuses in order to group them by status.
warn "Formatting the resulting action items....\n" if $debugActions;
warn "ACTIONS:\n" if $debugActions;
# my $actionTemplate = "<strong>[\$status]</strong> <strong>ACTION:</strong> \$action <br />\n";
my $actionTemplate = "[\$status] ACTION: \$action\n";
my @formattedActionLines = ();
foreach my $status (@actionStatuses)
	{
	my $n = 0;
	my $ucStatus = $actionStatuses{$status};
	foreach my $action (&CaseInsensitiveSort(keys %actions))
		{
		die if !exists($actions{$action});
		die if !defined($status);
		next if &LC($actions{$action}) ne &LC($status);
		my $s = $actionTemplate;
		$s =~ s/\$action/$action/;
		$s =~ s/\$status/$ucStatus/;
		push(@formattedActionLines, $s);
		$n++;
		delete($actions{$action});
		}
	push(@formattedActionLines, "\n") if $n>0;
	}
# There shouldn't be any more kinds of actions, but if there are, format them.
# $actions{'FAKE ACTION TEXT'} = 'OTHER_STATUS';	# Test
warn "Formatting remaining action items....\n" if $debugActions;
foreach my $status (sort values %actions)
	{
	my $n = 0;
	my $ucStatus = $actionStatuses{$status}; # Map to preferred spelling
	# foreach my $action (sort keys %actions)
	foreach my $action (&CaseInsensitiveSort(keys %actions))
		{
		die if !exists($actions{$action});
		die if !defined($status);
		next if &LC($actions{$action}) ne &LC($status);
		my $s = $actionTemplate;
		$s =~ s/\$action/$action/;
		$s =~ s/\$status/$ucStatus/;
		push(@formattedActionLines, $s);
		$n++;
		delete($actions{$action});
		}
	push(@formattedActionLines, "\n") if $n>0;
	}

# Try to break lines over 76 chars:
warn "Breaking lines over 76 chars....\n" if $debugActions;
@formattedActionLines = map { &BreakLine($_) } @formattedActionLines
	if $breakActions;
# Convert the @formattedActionLines to HTML.
# Add HTML line break to the end of each line:
@formattedActionLines = map { s/\n/ <br \/>\n/; $_ } @formattedActionLines;
# Change initial space (for continuation lines) to &nbsp;
@formattedActionLines = map { s/\A /\&nbsp\;/; $_ } @formattedActionLines;

my $formattedActions = join("", @formattedActionLines);
# Make links from URLs in actions:
warn "Making links in actions....\n" if $debugActions;
$formattedActions =~ s/(http\:([^\)\]\}\<\>\s\"\']+))/<a href=\"$1\">$1<\/a>/ig;

# Highlight ACTION items:
warn "Highlighting actions....\n" if $debugActions;
$formattedActions =~ s/\bACTION\s*\:(.*)/\<strong\>ACTION\:\<\/strong\>$1/ig;
# Highlight in-line ACTION status:
foreach my $status (@actionStatuses)
	{
	my $ucStatus = $actionStatuses{$status}; # Map to preferred spelling
	$formattedActions =~ s/\[$status\]/<strong>[$ucStatus]<\/strong>/ig;
	}
warn "Done formatting actions!\n" if $debugActions;

$all = &IgnoreGarbage($all);

if ($implicitContinuations)
	{
	# warn "Scribing style: -implicitContinuations\n";
	$all = &ExpandImplicitContinuations($all);
	}
else	{
	# warn "Scribing style: -explicitContinuations\n";
	if (&ProbablyUsesImplicitContinuations($all))
		{
		warn "\nWARNING: Input appears to use implicit continuation lines.\n";
		warn "You may need the \"-implicitContinuations\" option.\n\n";
		}
	}


if (0)
{
$all = &PutSpeakerOnEveryLine($all);
# Convert from:
#	<dbooth> DanC: something
#	<dbooth> DanC: something
#	<DanC> something
#	<DanC> something
#	<dbooth> DanC: something
#	<dbooth> ----
#	<dbooth> Whatever
# to:
#	DanC: something
#	 ... something
#	<DanC> something
#	 ... something
#	DanC: something
#	----------------------------------------
#	<dbooth> Whatever
my $prevSpeaker = "UNKNOWN_SPEAKER:";	# "DanC:" or "<DanC>"
my $prevPattern; # Initialized below
my @linesIn = split(/\n/, $all);
my @linesOut = ();
while (@linesIn)
	{
	my $line = shift @linesIn;
	warn "LINE (BEFORE): $line\n" if $debug;
	# Ignore empty lines
	if ($line =~ m/\A\s*\Z/)
		{
		warn "  BLANK: $line\n" if $debug;
		next;
		}
	# Determine rough line format
	my $writer = "";
	my $speaker = "";
	my $text = "";
	# <writer> speaker: text
	if ($line =~ m/\A\<([a-zA-Z0-9\-_\.]+)\>\s*([a-zA-Z0-9\-_\.]+)\s*\:\s*(.*?)\s*\Z/i )
		{
		$writer = $1;
		$speaker = $2;
		$text = $3;
		warn "FIRST match 1:$1 2:$2 3:$3 LINE: $line\n" if $debug;
		}
	# <writer> text
	elsif ($line =~ m/\A\<([a-zA-Z0-9\-_\.]+)\>\s*(.*?)\s*\Z/i )
		{
		$writer = $1;
		$speaker = "";
		$text = $2;
		warn "SECOND match 1:$1 2:$2 LINE: $line\n" if $debug;
		}
	else	{
		die "DIED FROM UNKNOWN LINE FORMAT: $line\n\n";
		}
	# Make lower case versions, for easier comparison
	die if !defined($writer);
	die if !defined($speaker);
	die if !defined($prevSpeaker);
	my $writerLC = &LC($writer);
	my $speakerLC = &LC($speaker);
	my $prevSpeakerLC = &LC($prevSpeaker);
	$prevPattern = quotemeta($prevSpeaker);
	warn "writerLC: $writerLC speakerLC: $speakerLC text: $text\n" if $debug;
	# warn "PHILIPPE: writerLC: $writerLC speakerLC: $speakerLC text: $text\n" if &Trim($speaker) eq "philippe";
	# warn "EMPTY TEXT: writerLC: $writerLC speakerLC: $speakerLC text: $text\n" if &Trim($text) eq "";
	# Process the various commands
	if (0) {}
	# Topic: ... 
	elsif ($speakerLC eq "topic")
		{
		warn "  TOPIC: $line\n" if $debug;
		# New topic.
		# Force the speaker name to be repeated next time
		$prevSpeaker = "UNKNOWN_SPEAKER:";	# "DanC:" or "<DanC>"
		}
	# Separator:
	#	<dbooth> ----
	elsif ($text =~ m/\A\-\-\-+\Z/ && !$speaker)
		{
		warn "  SEPARATOR1: $line\n" if $debug;
		my $dashes = '-' x 30;
		$line = $dashes;
		}
	# Separator:
	#	<dbooth> ====
	elsif ($text =~ m/\A\=\=\=+\Z/ && !$speaker)
		{
		warn "  SEPARATOR2: $line\n" if $debug;
		my $dashes = '=' x 30;
		$line = $dashes;
		}
	# Dots continuation line.
	# This commented out version is intended for when the "..." is
	# already on the line when we get here:
	# elsif ($line =~ s/\A\<scribe\>\s*($prevPattern)//i) 
	elsif ($line =~ s/\A\<scribe\>\s*($prevPattern)\s*/ ... /i) 
		{
		# $line = " ... $text";
		warn "  SAME SPEAKER: $line\n" if $debug;
		}
	# BUG: The \s* before the ":" in the pattern below doesn't work right,
	# because the ":" is stored as part of $prevSpeaker, so it
	# won't match right the next time "<dbooth> joe : whatever" is
	# encountered.
	elsif ($line =~ s/\A\<scribe\>\s*(($speakerPattern)\:)\s*/$1 /i )
		{
		warn "  NEW SPEAKER: $line\n" if $debug;
		# New speaker
		$prevSpeaker = "$1";
		$prevPattern = quotemeta($prevSpeaker);
		}
	elsif ($line =~ m/\A$prevPattern\s*.*\bACTION\s*\:/i)
		{
		warn "  ACTION: $line\n" if $debug;
		}
	elsif ($line =~ s/\A$prevPattern\s*/ ... /i)
		{
		warn "  SCRIBE CONTINUES: $line\n" if $debug;
		}
	elsif ($line =~ s/\A(\<scribe\>)\s*/Scribe\: /i )
		{
		warn "  SCRIBE SPEAKS: $line\n" if $debug;
		# Scribe speaks
		$prevSpeaker = $1;
		$prevPattern = quotemeta($prevSpeaker);
		# die "line: $line\n" if $line =~ m/Closing/;
		}
	elsif ($line =~ m/\A(\<$namePattern\>)/i)
		{
		warn "  IRC COMMENT: $line\n" if $debug;
		$prevSpeaker = $1;
		$prevPattern = quotemeta($prevSpeaker);
		}
	warn "LINE (AFTER): $line\n" if $debug;
	push(@linesOut, $line) if $line ne "";	# Default
	# die if $line =~ "Topic";
	}
$all = join("\n", @linesOut);
$all = "\n" . $all . "\n";	# Easier pattern matching
}

else
{
if (0)
{
warn "############# TEST DATA ONLY #############\n";
$all = '<scribe> dbooth: dbooth said 1
<scribe>  dbooth said 2 # This should be continuation
<hugo> Topic: New topic A
<scribe> ... dbooth said 3 # This should be speaker david
<scribe> dbooth: dbooth said 4 # This should be continuation
<scribe> Topic: New topic B
<scribe> ... dbooth said 5 # This should be UNKNOWN_SPEAKER
';
}
my $debugCurrentSpeaker = 0;
my @lines = split(/\n/, $all);
my $prevSpeaker = "UNKNOWN_SPEAKER"; # Most recent speaker minuted by scribe
my $pleaseContinue = 0;
for (my $i=0; $i<@lines; $i++)
	{
	my ($writer, $type, $value, $rest, $allButWriter) = &ParseLine($lines[$i]);
	warn "\nprevSpeaker: $prevSpeaker pleaseContinue: $pleaseContinue line: $lines[$i]\n" if $debugCurrentSpeaker;
	warn "writer: $writer, type: $type, value: $value, rest: $rest, allBut: $allButWriter\n" if $debugCurrentSpeaker;
	# $type	is one of: COMMAND STATUS SPEAKER CONTINUATION PLAIN ""
	next if $type eq "";
	if (&LC($writer) ne "scribe")
		{
		warn "writer NOT scribe\n" if $debugCurrentSpeaker;
		$pleaseContinue = 0;
		next;
		}
	# $writer is scribe
	if ($type eq "COMMAND") 
		{ 
		warn "type is COMMAND\n" if $debugCurrentSpeaker;
		$pleaseContinue = 0; 
		$prevSpeaker = "UNKNOWN_SPEAKER";
		}
	elsif ($type eq "STATUS") 
		{ 
		warn "type is STATUS\n" if $debugCurrentSpeaker;
		$pleaseContinue = 0; 
		$prevSpeaker = "UNKNOWN_SPEAKER";
		}
	elsif ($type eq "PLAIN") 
		{ 
		warn "type is PLAIN\n" if $debugCurrentSpeaker;
		$lines[$i] = "$rest"; # Eliminate <scribe>
		$pleaseContinue = 0; 
		$prevSpeaker = "scribe";
		}
	elsif ($type eq "SPEAKER")
		{
		warn "type is SPEAKER\n" if $debugCurrentSpeaker;
		if ($pleaseContinue && $value eq $prevSpeaker)
			{
			warn "  ... continuing\n" if $debugCurrentSpeaker;
			# "... rest" or
			# " rest"
			$lines[$i] = $preferredContinuation . $rest;
			}
		else	{
			warn "  Restating speaker\n" if $debugCurrentSpeaker;
			# speaker: rest
			$lines[$i] = "$value\: $rest";
			}
		$prevSpeaker = $value;
		$pleaseContinue = 1;
		}
	elsif ($type eq "CONTINUATION")
		{
		warn "type is CONTINUATION\n" if $debugCurrentSpeaker;
		if ($pleaseContinue)
			{
			warn "  ... continuing\n" if $debugCurrentSpeaker;
			# "... rest" or
			# " rest"
			$lines[$i] = $preferredContinuation . $rest;
			}
		else	{
			warn "  Restating speaker\n" if $debugCurrentSpeaker;
			# speaker: rest
			$lines[$i] = "$prevSpeaker\: $rest";
			}
		$pleaseContinue = 1;
		}
	else	{
		warn "INTERNAL ERROR: Unknown line type: ($type) returned by ParseLine(...)\n";
		}
	}
$all = "\n" . join("\n", @lines) . "\n";
}

# Experimental code (untested) commented out:
if (0) 
{
# warn "all: $all\n";
my ($newTemplate, %embeddedTemplates) = &GetEmbeddedTemplates($template);
foreach my $n (keys %embeddedTemplates)
	{
	warn "=============== template $n =================\n";
	warn $embeddedTemplates{$n} . "\n";
	warn "==============================================\n";
	}
}


######################### HTML ##########################
# From now on, $all is in HTML!!!!!
##############  Escape < > as &lt; &gt; ################
# Escape < and >:
$all =~ s/\&/\&amp\;/g;
$all =~ s/\</\&lt\;/g;
$all =~ s/\>/\&gt\;/g;
# $all =~ s/\"/\&quot\;/g;

# Highlight in-line ACTION items:
my @allLines = split(/\n/, $all);
for (my $i=0; $i<@allLines; $i++)
	{
	next if $allLines[$i] =~ m/\&gt\;\s*Topic\s*\:/i;
	$allLines[$i] =~ s/\bACTION\s*\:(.*)/\<strong\>ACTION\:\<\/strong\>$1/i;
	}
$all = "\n" . join("\n", @allLines) . "\n";

# Highlight in-line ACTION status:
foreach my $status (@actionStatuses)
	{
	my $ucStatus = $status;
	$ucStatus =~ tr/a-z/A-Z/; # Make upper case but not preferred spelling
	$all =~ s/\[\s*$status\s*\]/<strong>[$ucStatus]<\/strong>/ig;
	}

# Format topic titles (i.e., collect agenda):
my %agenda = ();
my $itemNum = "item01";
while ($all =~ s/\n(\&lt\;$namePattern\&gt\;\s+)?Topic\:\s*(.*)\n/\n$preTopicHTML id\=\"$itemNum\"\>$4$postTopicHTML\n/i)
	{
	$agenda{$itemNum} = $4;
	$itemNum++;
	}
if (!scalar(keys %agenda)) 	# No "Topic:"s found?
	{
	warn "\nWARNING: No \"Topic: ...\" lines found!  \nResulting HTML may have an empty (invalid) <ol>...</ol>.\n\nExplanation: \"Topic: ...\" lines are used to indicate the start of \nnew discussion topics or agenda items, such as:\n<dbooth> Topic: Review of Amy's report\n\n";
	}
my $agenda = "";
foreach my $item (sort keys %agenda)
	{
	$agenda .= '<li><a href="#' . $item . '">' . $agenda{$item} . "</a></li>\n";
	}
### @@@ Fix IRC/Phone distinctionxc
# Break into paragraphs:
$all =~ s/\n(([^\ \.\<\&].*)(\n\ *\.\.+.*)*)/\n$prePhoneParagraphHTML\n$1\n$postPhoneParagraphHTML\n/g;
$all =~ s/\n((&.*)(\n\ *\.\.+.*)*)/\n$preIRCParagraphHTML\n$1\n$postIRCParagraphHTML\n/g;

# Bold or <strong> speaker name:
# Change "<speaker> ..." to "<b><speaker><b> ..."
my $preUniq = "PreSpEaKerHTmL";
my $postUniq = "PostSpEaKerHTmL";
my $preIRCUniq = "PreIrCSpEaKerHTmL";
my $postIRCUniq = "PostIrCSpEaKerHTmL";
$all =~ s/\n(\&lt\;($namePattern)\&gt\;)\s*/\n\&lt\;$preIRCUniq$2$postIRCUniq\&gt\; /ig;
# Change "speaker: ..." to "<b>speaker:<b> ..."
$all =~ s/\n($speakerPattern)\:\s*/\n$preUniq$1\:$postUniq /ig;
$all =~ s/$preUniq/$preSpeakerHTML/g;
$all =~ s/$postUniq/$postSpeakerHTML/g;
$all =~ s/$preIRCUniq/$preIRCSpeakerHTML/g;
$all =~ s/$postIRCUniq/$postIRCSpeakerHTML/g;


# Add <br /> before continuation lines:
$all =~ s/\n(\ *\.)/ <br>\n$1/g;
# Collapse multiple <br />s:
$all =~ s/<br>((\s*<br>)+)/<br \/>/g;
# Standardize continuation lines:
# $all =~ s/\n\s*\.+/\n\.\.\./g;
# Make links:
$all =~ s/(http\:([^\)\]\}\<\>\s\"\']+))/<a href=\"$1\">$1<\/a>/ig;

# Put into template:
# $all =~ s/\A\s*<\/p>//;
# $all .= "\n<\/p>\n";
my $presentAttendees = join(", ", @present);
my $regrets = join(", ", @regrets);

die if !$template;
my $result = $template;
$result =~ s/SV_MEETING_DAY/$day0/g;
$result =~ s/SV_MEETING_MONTH_ALPHA/$monthAlpha/g;
$result =~ s/SV_MEETING_YEAR/$year/g;
$result =~ s/SV_MEETING_MONTH_NUMERIC/$mon0/g;
$result =~ s/SV_PREVIOUS_MEETING_URL/$previousURL/g;
$result =~ s/SV_MEETING_CHAIR/$chair/g;
$result =~ s/SV_MEETING_SCRIBE/$scribeName/g;
$result =~ s/SV_MEETING_AGENDA/$agenda/g;
$result =~ s/SV_TEAM_PAGE_LOCATION/SV_TEAM_PAGE_LOCATION/g;

$result =~ s/SV_REGRETS/$regrets/g;
$result =~ s/SV_PRESENT_ATTENDEES/$presentAttendees/g;
if ($result !~ s/SV_ACTION_ITEMS/$formattedActions/)
	{
	if ($result =~ s/SV_NEW_ACTION_ITEMS/$formattedActions/)
		{ warn "\nWARNING: Template format has changed.  SV_NEW_ACTION_ITEMS should now be SV_ACTION_ITEMS\n\n"; }
	else { warn "\nWARNING: SV_ACTION_ITEMS marker not found in template!\n\n"; } 
	}
$result =~ s/SV_AGENDA_BODIES/$all/;
$result =~ s/SV_MEETING_TITLE/$title/g;

# Version
$result =~ s/SCRIBEPERL_VERSION/$CVS_VERSION/;

my $formattedLogURL = '<p>See also: <a href="SV_MEETING_IRC_URL">IRC log</a></p>';
if ($logURL eq "SV_MEETING_IRC_URL")
	{
	warn "\nWARNING: Missing IRC LOG!\n\n";
	$formattedLogURL = "";
	}
$formattedLogURL = "" if $logURL =~ m/\ANone\Z/i;
$result =~ s/SV_FORMATTED_IRC_URL/$formattedLogURL/g;
$result =~ s/SV_MEETING_IRC_URL/$logURL/g;

my $formattedAgendaLocation = '';
if ($agendaLocation) {
    $formattedAgendaLocation = "<p><a href='$agendaLocation'>Agenda</a></p>\n";
}
$result =~ s/SV_FORMATTED_AGENDA_LINK/$formattedAgendaLocation/g;

print $result;

#### Output seems to be normally valid now.
# warn "\nWARNING: There is currently a bug that causes this program to\ngenerate INVALID HTML!  You can correct it by piping the output \nthrough \"tidy -c\".   If you have tidy installed, you can use \nthe -tidy option to do so.  Otherwise, run the W3C validator to find \nand fix the error: http://validator.w3.org/\n\n";
exit 0;
################### END OF MAIN ######################

#################################################################
#################### SetScribeNameAndNick #######################
#################################################################
# Decide what $scribeNick to use, and modify $all to change
# <$scribeNick> lines to <scribe> lines.
sub SetScribeNameAndNick
{
@_ == 3 || die;
my ($scribeName, $scribeNick, $all) = @_;
my $guessedScribeNick = &GuessScribeNick($all);
# Cannot guess the scribe when Plain_Text_Format format is used.
$guessedScribeNick = "scribe" if ($bestName eq "Plain_Text_Format");
my $guessedScribePattern = quotemeta($guessedScribeNick);
# warn "guessedScribePattern: $guessedScribePattern\n";
my $scribeNamePattern = quotemeta($scribeName);
# warn "scribeNamePattern: $scribeNamePattern\n";
my $scribeNickPattern = quotemeta($scribeNick);
# warn "scribeNickPattern: $scribeNickPattern\n";

# Replace scribe name with "scribe".  I.e., change
#	<dbooth> Minutes approved
# to
#	<scribe> Minutes approved
$all = "\n$all\n";
# WARNING: Pattern match (annoyingly) returns "" if no match -- not 0.
my $nScribeLines = ($all =~ s/\n\<scribe\>/\n\<scribe\>/ig);
$nScribeLines = 0 if $nScribeLines eq ""; # Make 0 if no match
# warn "nScribeLines: $nScribeLines\n";

my $tempScribeNameAll = $all;
my $nScribeNameLines = ($tempScribeNameAll =~ s/\n\<$scribeNamePattern\>/\n\<scribe\>/ig);
$nScribeNameLines = 0 if $nScribeNameLines eq ""; # Make 0 if no match
$nScribeNameLines = 0 if $scribeName eq ""; # Make 0 if no $scribeName
# warn "nScribeNameLines: $nScribeNameLines\n";

my $tempScribeNickAll = $all;
my $nScribeNickLines = ($tempScribeNickAll =~ s/\n\<$scribeNickPattern\>/\n\<scribe\>/ig);
$nScribeNickLines = 0 if $nScribeNickLines eq ""; # Make 0 if no match
$nScribeNickLines = 0 if !$scribeNick; 		# Make 0 if no $scribeNick
# warn "nScribeNickLines: $nScribeNickLines\n";

my $tempGuessedScribeAll = $all;
my $nGuessedScribeLines = ($tempGuessedScribeAll =~ s/\n\<$guessedScribePattern\>/\n\<scribe\>/ig);
$nGuessedScribeLines = 0 if $nGuessedScribeLines eq ""; # Make 0 if no match
$nGuessedScribeLines = 0 if !$guessedScribeNick;
# warn "nGuessedScribeLines: $nGuessedScribeLines\n";

if ($scribeNick)
	{
	$all = $tempScribeNickAll;
	if (!$nScribeNickLines)
		{
		warn "\nWARNING: No <$scribeNick> lines found.\n";
		if ($nScribeNameLines > $nGuessedScribeLines)
			{
			$scribeNick = $scribeName;
			$all = $tempScribeNameAll;
			}
		else	{
			$scribeNick = $guessedScribeNick;
			$all = $tempGuessedScribeAll;
			}
		warn "Instead using ScribeNick: $scribeNick\n\n";
		}
	$scribeName = $scribeNick if !$scribeName;
	}
elsif ($scribeName)
	{
	$scribeNick = $scribeName;
	$all = $tempScribeNameAll;
	if (!$nScribeNameLines)
		{
		warn "\nWARNING: No <$scribeName> lines found.\n";
		$scribeNick = $guessedScribeNick;
		warn "Guessing ScribeNick: $scribeNick\n\n";
		$all = $tempGuessedScribeAll;
		}
	}
else	{
	warn "\nWARNING: No Scribe or ScribeNick specified.\n";
	$scribeNick = $guessedScribeNick;
	warn "Guessing ScribeNick: $scribeNick\n";
	warn "You can specify the Scribe's IRC name like this:\n";
	warn "  <$scribeNick> ScribeNick: $scribeNick\n";
	warn "You can also specify the Scribe's full name like this:\n";
	warn "  <$scribeNick> Scribe: David_Booth\n\n";
	$all = $tempGuessedScribeAll;
	}

return ($scribeName, $scribeNick, $all);
}

######################################################################
######################## ConvertDashTopics ###########################
######################################################################
# Treat dash lines as starting a new topic:
#	<Philippe> ---
#	<Philippe> UTF16 PR issue
# as equivalent to:
#	<Philippe> Topic: UTF16 PR issue
sub ConvertDashTopics
{
@_ == 1 || die;
my ($all) = @_;
my $nFound = 0;
my @lines = split(/\n/, $all);
for(my $i=0; $i<@lines-1; $i++)
	{
	my ($writer, $type, undef, $rest, undef) = &ParseLine($lines[$i]);
	# Dash separator line?  <Philippe> ---
	next if ($type ne "PLAIN" || $rest !~ m/\A\-+\Z/);
	# Some other writer may have said something
	# between the dash separator line and the topic line, 
	# so look forward for the next line by the same writer.
	INNER: for (my $j=$i+1; $j<@lines; $j++)
		{
		my ($writer2, $type2, $value2, undef, $allButWriter2) = &ParseLine($lines[$j]);
		# Same writer?
		next if $writer2 ne $writer;
		# Empty lines don't count.
		next if $type2 eq "";
		next if $allButWriter2 eq "";
		# warn "writer2: $writer2 type2: $type2 value2: $value2 allButWriter2: $allButWriter2 lines[j]: $lines[$j]\n";
		# Do nothing if the next scribe line is a Topic: command anyway
		last INNER if ($type2 eq "COMMAND" && &LC($value2) eq "topic");
		# Turn: 
		#	<Philippe> UTF16 PR issue
		# into: 
		#	<Philippe> Topic: UTF16 PR issue
		$lines[$j] = "\<$writer\> Topic: $allButWriter2";
		$nFound++;
		# $type2 is one of: COMMAND STATUS SPEAKER CONTINUATION PLAIN ""
		if ($type2 eq "COMMAND" || $type2 eq "STATUS" 
			|| ($type2 eq "CONTINUATION" && $value2 !~ m/\A\s*\Z/))
			{
			warn "\nWARNING: Unusual topic line found after \"$rest\" topic separator:" . $lines[$j] . "\n\n" if $dashTopics;
			# warn "value2: $value2\n";
			}
		last INNER;
		}
	}
$all = "\n" . join("\n", @lines) . "\n";
return($all, $nFound);
}

###############################################################
################# WordVariationsMap ###########################
###############################################################
# Generates word variations and returns a map from each lower case
# variation to the preferred (original) mixed case form.
sub WordVariationsMap
{
my @words = @_;	# Preferred mixed case words.
my %map = ();	# Maps each lower case variation to preferred mixed case form.
foreach my $w (@words)
	{
	die if (!defined($w)) || $w eq "";
	my @variations = &WordVariations(&LC($w));
	foreach my $v (@variations)
		{
		$map{$v} = $w;
		}
	}
return(%map);
}

###################################################################
####################### WordVariations #######################
###################################################################
# Generate spelling variations of the given words, e.g.
#	Previous_Minutes
#	Previous-Minutes
#	Previous Minutes
#	PreviousMinutes
sub WordVariations
{
my @old = @_;
my @new = map { 
		my @w=($_); 
		# Allow variations of multiword words:
		push(@w, $_) if ($_ =~ s/[_\-\ ]+/\_/g); # Previous_Minutes
		push(@w, $_) if ($_ =~ s/[_\-\ ]+/\-/g); # Previous-Minutes
		push(@w, $_) if ($_ =~ s/[_\-\ ]+/\ /g); # Previous Minutes
		push(@w, $_) if ($_ =~ s/[_\-\ ]+//g);   # PreviousMinutes
		# warn "VARIATIONS: @w\n";
		&Uniq(@w);
		} @old;
return(@new);
}

###################################################################
####################### Uniq #######################
###################################################################
# Return one copy of each thing in the given list.
# Order is preserved.
sub Uniq
{
my @words = @_;
my %seen = ();
my @result = ();
foreach my $w (@words)
	{
	next if exists($seen{$w});
	$seen{$w} = $w;
	push(@result, $w);
	}
return(@result);
}

###################################################################
####################### MakePattern2 #######################
###################################################################
# Generate a pattern matching any of the given words, e.g.:
#	dog|cat|pig
# Compound words may be given, such as "Big Dog", "Big-Dog" or "Big_Dog",
# in which case they are converted to patterns that match any form:
#	Big[ _\-]?Dog
# which will match any of:
#	"BigDog", "Big_Dog", "Big-Dog" or "Big Dog"
# No parentheses are used, so you should put parens around the
# resulting pattern.
sub MakePattern2
{
# ***  This is a new, untested version.  It should make WordVariations obsolete.
@_ > 0 || die;
my @words = grep {die if (!defined($_)) || $_ eq ""; $_} @_;
@words = map {s/[ _\-]/_/g; $_} @words; # Big-Dog --> Big_Dog
@words = map {quotemeta($_)} @words;
@words = map {s/_/\[ _\\\-\]\?/g; $_} @words; # Big_Dog --> Big[ _\-]?Dog
my $pattern =  join("|", @words);
return $pattern;
}

###################################################################
####################### MakePattern #######################
###################################################################
# Generate a pattern matching any of the given words, e.g.:
#	dog|cat|pig
# No parentheses are used, so you should put parens around the
# resulting pattern.
sub MakePattern
{
@_ > 0 || die;
my @words = grep {die if (!defined($_)) || $_ eq ""; $_} @_;
my $pattern =  join("|", map {quotemeta($_)} @words);
return $pattern;
}


###################################################################
####################### ParseLine #######################
###################################################################
# Parse the line and return:
#	$writer		E.g. dbooth from "<dbooth> ..."
#	$type		One of: COMMAND STATUS SPEAKER CONTINUATION PLAIN ""
#	$value		Either: the command; the speaker; the continuation
#			pattern; the status; or empty (if $type is PLAIN).
#			WARNING: $value may be mixed case.  Use &LC($value)
#			for lower case.  (Not sure if this is the right choice
#			here.  Does anything need it in mixed case?  Maybe
#			it should always be returned in lower case.)
#	$rest		The rest of the line (no $writer or $value), &Trim()'ed
#	$allButWriter	All but the <writer> part, &Trim()'ed.
# (I.e., $type is "" if no writer.)
sub ParseLine
{
@_ == 1 || die;
my ($line) = @_;
my ($writer, $type, $value, $rest, $allButWriter) = ("", "", "", "", "");
# Remove "<dbooth> " from the $line
if ($line !~ s/\A(\s?)\<([\w\_\-\.]+)\>(\s?)//)
	{
	# No <writer>.
	$rest = &Trim($line);
	$allButWriter = $rest;
	return ($writer, $type, $value, $rest, $allButWriter);
	}
# "<dbooth> " has now been removed from the $line
$writer = $2;
$allButWriter = &Trim($line);
# Action status?
if ($line =~ m/\A\W*($actionStatusesPattern)\W*/i)
	{
	$type = "STATUS";
	$value = $1;
	$rest = $';
	# die "LINETYPE a s type: $type value: $value rest: $rest\n";
	#### Don't map to preferred spelling.  Keep existing spelling.
	if (0)
		{
		$value = $actionStatuses{&LC($value)}; # Map to pref spelling
		}
	else	{
		$value =~ tr/a-z/A-Z/; # Make upper case but not pref spelling
		}
	}
# Command?
# This pattern allows up to two *extra* leading spaces for commands
elsif ($line =~ m/\A(\s?(\s?))($commandsPattern)(\s?)\:\s*/i)
	{
	$type = "COMMAND";
	$value = $3;
	$rest = $';
	# Put command in canonical form (no spaces or underscore):
	if (!exists($commands{&LC($value)}))
		{
		die "ParseLine value: $value line: $line\n" if $line =~ m/topic/i;
		}
	$value = $commands{&LC($value)}; # previous_meeting --> Previous_Meeting
	}
# Speaker statement?
# This pattern allows up to two *extra* leading spaces for speaker statements
elsif ($line =~ m/\A(\s?)(\s?)([_\w\-\.]+)(\s?)\:\s*/)
	{
	$value = $3;
	$rest = $';
	# Make sure it's not in the stopList (non-name).
	if (!exists($stopList{&LC($value)}))
		{
		# Must be a speaker statement.
		$type = "SPEAKER";
		}
	}
# Continuation line?
if ((!$type) && $line =~ m/\A((\s)|(\s?(\s?)\.\.+(\s?)(\s?)))/)
	{
	$type = "CONTINUATION";
	$value = $&;
	$rest = $';
	if ($value =~ m/\./) { $value = "... "; } # Standardize
	else { $value = " "; }
	}
if (!$type)
	{
	# Must be plain line
	$value = "";
	$rest = $line;
	$type = "PLAIN";
	}
$rest = &Trim($rest);
return ($writer, $type, $value, $rest, $allButWriter);
}

###################################################################
####################### CaseInsensitiveSort #######################
###################################################################
sub CaseInsensitiveSort
{
return( sort {&LC($a) cmp &LC($b)} @_ );
}

###################################################################
####################### GetPresentFromZakim ##########################
###################################################################
# Get the list of people present, as reported by zakim bot:
#	<Zakim> Attendees were Dbooth, Dietmar_Gaertner, Plh, GlenD,
#	<Zakim> ... IgorS, J.Mischkinsky, Lily, Umit, sanjiva, bijan,
sub GetPresentFromZakim
{
@_ == 1 || die;
my ($all) = @_;
die if !defined($all);
my @present = ();			# People present at the meeting
my @zakimLines = grep {s/\A\<Zakim\>\s*//i;} split(/\n/, $all);
my $t = join("\n", grep {s/\A\<Zakim\>\s*//i;} split(/\n/, $all)); 
# Join zakim continuation lines
$t =~ s/\n\.\.\.\.*\s*/ /g;
# die "t:\n$t\n" . ('=' x 70) . "\n\n";
@zakimLines = split(/\n/, $t);
foreach my $line (@zakimLines)
	{
	if ($line =~ m/Attendees\s+((were)|(have\s+been))\s+/i)
		{
		my $raw = $';
		my @people = map {$_ = &Trim($_); s/\s+/_/g; $_} split(/\,/, $raw);
		next if !@people;
		if (@present)
			{
			warn "\nWARNING: Replacing list of attendees.\nOld list: @present\nNew list: @people\n\n";
			}
		@present = @people;
		}
	}
return(@present);
}

###################################################################
####################### GetPresentOrRegrets ##########################
###################################################################
# Look for explicit "Present: ..." or "Regrets: ..." commands.
# Arguments: $keyword, $minPeople, $all, @present (default)
# Returns: ($all, @present)
# $all is modified by removing any "Present: ..." commands.
sub GetPresentOrRegrets
{
@_ >= 3 || die;
my (	$keyword, 	# What we're looking for: "Present" or "Regrets"
	$minPeople, 	# Min number of people to avoid a warning
	$all, 		# The input
	@present	# Default people present at the meeting
	) = @_;
die if !defined($all);
my @allLines = split(/\n/, $all);
# <dbooth> Present: Amy Frank Joe Carol
# <dbooth> Present: David Booth, Frank G, Joe Camel, Carole King
# <dbooth> Present+: Justin
# <dbooth> Present+ Silas
# <dbooth> Present-: Amy
my @possiblyPresent = @uniqNames;	# People present at the meeting
my @newAllLines = ();	# Collect remaining lines
# push(@allLines, "<dbooth> Present: David Booth, Frank G, Joe Camel, Carole King"); # test
# push(@allLines, "<dbooth> Present: Amy Frank Joe Carole"); # test
# push(@allLines, "<dbooth> Present+: Justin"); # test
# push(@allLines, "<dbooth> Present+ Silas"); # test
# push(@allLines, "<dbooth> Present-: Amy"); # test
my $isAlreadyDefined = 0;
foreach my $line (@allLines)
	{
	$line =~ s/\s+\Z//; # Remove trailing spaces.
	if ($line !~ m/\A\<[^\>]+\>\s*$keyword\s*(\:|((\+|\-)\s*\:?))\s*(.*)\Z/i)
		{
		push(@newAllLines, $line);
		next;
		}
	my $plus = $1;
	my $present = $4;
	my @p = ();
	if ($present =~ m/\,/)
		{
		# Comma-separated list
		@p = grep {$_ && $_ ne "and"} 
				map {$_ = &Trim($_); s/\s+/_/g; $_} 
				split(/\,/,$present);
		}
	else	{
		# Space-separated list
		@p = grep {$_} split(/\s+/,$present);
		}
	if ($plus =~ m/\+/)
		{
		my %seen = map {($_,$_)} @present;
		my @newp = grep {!exists($seen{$_})} @p;
		push(@present, @newp);
		}
	elsif ($plus =~ m/\-/)
		{
		my %seen = map {($_,$_)} @present;
		foreach my $p (@p)
			{
			delete $seen{$p} if exists($seen{$p});
			}
		@present = sort keys %seen;
		}
	else	{
		warn "\nWARNING: Replacing previous list of people present.\nUse '$keyword\+ ... ' if you meant to add people without replacing the list,\nsuch as: <dbooth> $keyword\+ " . join(', ', @p) . "\n\n" if @present && $isAlreadyDefined;
		@present = @p;
		$isAlreadyDefined = 1;
		}
	}
@allLines = @newAllLines;
$all = "\n" . join("\n", @allLines) . "\n";
if (@present == 0)	
	{
	warn "\nWARNING: No \"$keyword\: ... \" found!\n";
	warn "Possibly Present: @possiblyPresent\n" if $keyword eq "Present"; 
	warn "You can indicate people for the $keyword list like this:
<dbooth> $keyword\: dbooth jonathan mary
<dbooth> $keyword\+ amy\n\n";
	}
else	{
	warn "$keyword\: @present\n"; 
	warn "\nWARNING: Fewer than $minPeople people found for $keyword list!\n\n" if @present < $minPeople;
	}
return ($all, @present);
}

#######################################################################
################## PutSpeakerOnEveryLine ######################
#######################################################################
# Canonicalize Scribe continuation lines so that the speaker's name is 
# on every line.  Convert:
#	<dbooth> Scribe: dbooth
#	<dbooth> SusanW: We had a mtg on July 16.
#	<DanC_> pointer to minutes?
#	<dbooth> SusanW: I'm looking.
#	<dbooth> ... The minutes are on
#	<dbooth>  the admin timeline page.
# to:
#	<dbooth> Scribe: dbooth
#	<dbooth> SusanW: We had a mtg on July 16.
#	<DanC_> pointer to minutes?
#	<dbooth> SusanW: I'm looking.
#	<dbooth> SusanW: The minutes are on
#	<dbooth> SusanW: the admin timeline page.
# Unfortunately, I don't remember why I did this.  I assume it was to
# make subsequent processing easier, but now I don't know why it is needed.
sub PutSpeakerOnEveryLine
{
@_ == 1 || die;
my ($all) = @_;
my @allLines = split(/\n/, $all);
my $currentSpeaker = "UNKNOWN_SPEAKER";
for (my $i=0; $i<@allLines; $i++)
	{
	# warn "$allLines[$i]\n" if $allLines[$i] =~ m/Liam/;
	if ($allLines[$i] =~ m/\A\<scribe\>(\s?\s?)($speakerPattern)\s*\:/i)
		{
		# The $speakerPattern in the pattern match above is
		# constructed from all of the known speaker names, so 
		# it will NOT match "Topic" or other keywords.
		# But to be safe, let's check it against the %stopList anyway.
		my $cs = $2;
		my $lccs = &LC($cs);
		$currentSpeaker = $cs if !exists($stopList{$lccs});
		}
	# Dot continuation line: "<dbooth> ... The minutes are on".
	# I'm not sure the following is right.  If there is a continuation
	# line after a non-speaker line, such as "Topic: whatever", then
	# I think this will act as a continuation of the previous speaker
	# line, which may not be the right thing to do.
	# (Rather, it probably should be a continuation line of the topic.)
	# I think the code for this program should be restructured, to
	# act globally on one line at a time, with look-ahead used to
	# join continuation lines on to the current line.
	# The following commented out version is for when the code is changed
	# to not remove (and later replace) the "...":
	# elsif ($allLines[$i] =~ s/\A\<scribe\>(\s?)\.\./\<scribe\> $currentSpeaker: ../i)
	elsif ($allLines[$i] =~ s/\A\<scribe\>(\s?)\.\.+(\s?)/\<scribe\> $currentSpeaker: /i)
		{
		# warn "Scribe NORMALIZED: $& --> $allLines[$i]\n";
		warn "\nWARNING: UNKNOWN SPEAKER: $allLines[$i]\nPossibly need to add line: <Zakim> +someone\n\n" if $currentSpeaker eq "UNKNOWN_SPEAKER";
		}
	# Leading-blank continuation line: "<dbooth>  the admin timeline page.".
	elsif ($allLines[$i] =~ s/\A\<scribe\>\s\s/\<scribe\> $currentSpeaker:  /i)
		{
		# warn "Scribe NORMALIZED: $& --> $allLines[$i]\n";
		warn "\nWARNING: UNKNOWN SPEAKER: $allLines[$i]\nPossibly need to add line: <Zakim> +someone\n\n" if $currentSpeaker eq "UNKNOWN_SPEAKER";
		}
	else	{
		}
	}
$all = "\n" . join("\n", @allLines) . "\n";
# die "all:\n$all\n" . ('=' x 70) . "\n\n";
return $all;
}


#################################################################
################# GuessScribeNick #################
#################################################################
# Guess the scribe IRC nickname based on who wrote the most in the log.
sub GuessScribeNick
{
@_ == 1 || die;
my ($all) = @_;
$all = &IgnoreGarbage($all);
my @lines = split(/\n/, $all);
my $nLines = 0;	# Total number of "<someone> something " lines.
my %nameCounts = (); # Count of the number of lines written per person.
my %mixedCaseNames = (); # Map from lower case name to mixed case name
foreach my $line (@lines)
	{
	if ($line =~ m/\A\<([^\>]+)\>/)
		{
		$nLines++;
		my $mix = $1;	# Liam
		my $who = &LC($mix);	# liam
		$nameCounts{$who}++;
		$mixedCaseNames{$who} = $mix; # liam -> Liam
		}
	}
my @descending = sort { $nameCounts{$b} <=> $nameCounts{$a} } keys %nameCounts;
# warn "Names in descending order:\n";
foreach my $n (@descending)
	{
	# warn "	$nameCounts{$n} $n\n";
	}
# warn "\n";
return "" if !@descending; # None
return $mixedCaseNames{$descending[0]};
}


#################################################################
################# IgnoreGarbage #################
#################################################################
# Ignore off-record lines and other lines that should not be minuted.
sub IgnoreGarbage
{
@_ == 1 || die;
my ($all) = @_;
my @lines = split(/\n/, $all);
my $nLines = scalar(@lines);
# warn "Lines found: $nLines\n";
my @scribeLines = ();
foreach my $line (@lines)
	{
	next if &IsIgnorable($line);
	# warn "KEPT: $line\n";
	push(@scribeLines, $line);
	}
my $nScribeLines = scalar(@scribeLines);
# warn "Minuted lines found: $nScribeLines\n";
$all = "\n" . join("\n", @scribeLines) . "\n";

# Verify that we axed all join/leave lines:
my @matches = ($all =~ m/.*has joined.*\n/g);
warn "\nWARNING: Possible internal error: join/leave lines remaining: \n\t" . join("\t", @matches) . "\n\n"
 	if @matches;
return $all;
}

#################################################################
#################### IsBotLine ###############################
#################################################################
# Given a single line, returns 1 if it is an IRC, Zakim or RRSAgent command
# or response.
sub IsBotLine
{
@_ == 1 || die;
my ($line) = @_;
die if $line =~ m/\n/; # Should be given only one line (with no \n).
# Join/leave lines:
return 1 if $line =~ m/\A\s*\<($namePattern)\>\s*\1\s+has\s+(joined|left|departed|quit)\s*((\S+)?)\s*\Z/i;
return 1 if $line =~ m/\A\s*\<(scribe)\>\s*$namePattern\s+has\s+(joined|left|departed|quit)\s*((\S+)?)\s*\Z/i;
# Topic change lines:
# <geoff_a> geoff_a has changed the topic to: Trout Mask Replica
return 1 if $line =~ m/\A\s*\<($namePattern)\>\s*\1\s+(has\s+changed\s+the\s+topic\s+to\s*\:.*)\Z/i;
return 1 if $line =~ m/\A\s*\<scribe\>\s*($namePattern)\s+(has\s+changed\s+the\s+topic\s+to\s*\:.*)\Z/i;
# Zakim lines
return 1 if $line =~ m/\A\<Zakim\>/i;
return 1 if $line =~ m/\A\<$namePattern\>\s*zakim\s*\,/i;
return 1 if $line =~ m/\A\<$namePattern\>\s*agenda\s*\d*\s*[\+\-\=\?]/i;
return 1 if $line =~ m/\A\<$namePattern\>\s*close\s+agend(a|(um))\s+\d+\Z/i;
return 1 if $line =~ m/\A\<$namePattern\>\s*open\s+agend(a|(um))\s+\d+\Z/i;
return 1 if $line =~ m/\A\<$namePattern\>\s*take\s+up\s+agend(a|(um))\s+\d+\Z/i;
return 1 if $line =~ m/\A\<$namePattern\>\s*q\s*[\+\-\=\?]/i;
return 1 if $line =~ m/\A\<$namePattern\>\s*queue\s*[\+\-\=\?]/i;
return 1 if $line =~ m/\A\<$namePattern\>\s*ack\s+$namePattern\s*\Z/i;
# RRSAgent lines
return 1 if $line =~ m/\A\<RRSAgent\>/i;
return 1 if $line =~ m/\A\<$namePattern\>\s*RRSAgent\s*\,/i;
# If we get here, it isn't a bot line.
# warn "KEPT: $line\n";
return 0;
}

#################################################################
#################### IsIgnorableOtherBotLine ###############################
#################################################################
# Given a single line, returns 1 if it is some other bot command or line
# that should be ignored.
sub IsIgnorableOtherBotLine
{
@_ == 1 || die;
my ($line) = @_;
die if $line =~ m/\n/; # Should be given only one line (with no \n).
# Join/leave lines:
return 1 if $line =~ m/\A\s*\<($namePattern)\>\s*\1\s+has\s+(joined|left|departed|quit)\s*((\S+)?)\s*\Z/i;
return 1 if $line =~ m/\A\s*\<(scribe)\>\s*$namePattern\s+has\s+(joined|left|departed|quit)\s*((\S+)?)\s*\Z/i;
# Topic change lines:
# <geoff_a> geoff_a has changed the topic to: Trout Mask Replica
return 1 if $line =~ m/\A\s*\<($namePattern)\>\s*\1\s+(has\s+changed\s+the\s+topic\s+to\s*\:.*)\Z/i;
return 1 if $line =~ m/\A\s*\<scribe\>\s*($namePattern)\s+(has\s+changed\s+the\s+topic\s+to\s*\:.*)\Z/i;
# If we get here, it isn't a bot line.
# warn "KEPT: $line\n";
return 0;
}

#################################################################
#################### IsIgnorableRRSAgentLine ###############################
#################################################################
# Given a single line, returns 1 if it is a RRSAgent command
# or response that should be ignored.
sub IsIgnorableRRSAgentLine
{
@_ == 1 || die;
my ($line) = @_;
die if $line =~ m/\n/; # Should be given only one line (with no \n).
# RRSAgent lines
return 1 if $line =~ m/\A\<RRSAgent\>/i;
return 1 if $line =~ m/\A\<$namePattern\>\s*RRSAgent\s*\,/i;
# If we get here, it isn't a bot line.
# warn "KEPT: $line\n";
return 0;
}

#################################################################
#################### IsIgnorableZakimLine ###############################
#################################################################
# Given a single line, returns 1 if it is a Zakim command
# or response that should be ignored.
sub IsIgnorableZakimLine
{
@_ == 1 || die;
my ($line) = @_;
die if $line =~ m/\n/; # Should be given only one line (with no \n).
# Zakim lines to specifically keep
# <Zakim> chaalsNCE, you wanted to say AC members should have priority 
return 0 if $line =~ m/\A\<Zakim\>\s*\S+\, you wanted to /i;
# Zakim lines to ignore
return 1 if $line =~ m/\A\<Zakim\>/i;
return 1 if $line =~ m/\A\<$namePattern\>\s*zakim\s*\,/i;
return 1 if $line =~ m/\A\<$namePattern\>\s*agenda\s*\d*\s*[\+\-\=\?]/i;
return 1 if $line =~ m/\A\<$namePattern\>\s*close\s+agend(a|(um))\s+\d+\Z/i;
return 1 if $line =~ m/\A\<$namePattern\>\s*open\s+agend(a|(um))\s+\d+\Z/i;
return 1 if $line =~ m/\A\<$namePattern\>\s*take\s+up\s+agend(a|(um))\s+\d+\Z/i;
return 1 if $line =~ m/\A\<$namePattern\>\s*q\s*[\+\-\=\?]/i;
return 1 if $line =~ m/\A\<$namePattern\>\s*queue\s*[\+\-\=\?]/i;
return 1 if $line =~ m/\A\<$namePattern\>\s*ack\s+$namePattern\s*\Z/i;
# If we get here, it isn't a Zakim line or Zakim command.
# warn "KEPT: $line\n";
return 0;
}

#################################################################
#################### IsIgnorable ################################
#################################################################
# Should the given line be ignored?
sub IsIgnorable
{
@_ == 1 || die;
my ($line) = @_;
die if $line =~ m/\n/; # Should be given only one line (with no \n).
# Ignore empty lines.
return 1 if &Trim($line) eq "";
# Ignore /me lines.  Up to 3 leading spaces before "*". (No <speaker>)
return 1 if $line =~ m/\A(\s?)(\s?)(\s?)\*/;
# Select only <speaker> lines
return 1 if $line !~ m/\A\<$namePattern\>/i;
# Ignore empty lines
return 1 if $line =~ m/\A\<$namePattern\>\s*\Z/i;
# Ignore bot lines
return 1 if &IsIgnorableZakimLine($line);
return 1 if &IsIgnorableRRSAgentLine($line);
return 1 if &IsIgnorableOtherBotLine($line);
# Remove off the record comments:
return 1 if $line =~ m/\A\<$namePattern\>\s*\[\s*off\s*\]/i;
# Select only <scribe> lines?
return 1 if $scribeOnly && $line !~ m/\A\<scribe\>/i;
# If we get here, we're keeping the line.
# warn "KEPT: $line\n";
return 0;
}

#################################################################
########################## BreakLine ###########################
#################################################################
# Try to break lines longer than $maxLineLength chars.
# Continuation lines are indented by a space.
# Input line should end with a newline;
# resulting lines will end with newlines.
# Lines are only broken at spaces.  Long words are never broken.
# Hence, the resulting line length may exceed the given $maxLineLength
# if there is a word that is longer than $maxLineLength (such as
# a URL).
sub BreakLine
{
@_ == 1 || @_ == 2 || die;
my ($line, $maxLineLength) = @_;
$maxLineLength = 76 if !defined($maxLineLength);
die if $line !~ m/\n\Z/;
my @result = ();
my $newLine = "";
my $nextWord = "";
while (1)
	{
	$newLine .= $nextWord;		# Append to $newLine
	last if ($line !~ s/\A\s*\S+//);	# Grab next word
	$nextWord = $&;
	if (length($newLine) > 0
	  && length($newLine) + length($nextWord) > $maxLineLength)
		{
		$newLine .= "\n";
		push(@result, $newLine);
		$newLine = " ";
		}
	}
$newLine .= "\n";
push(@result, $newLine);
return(@result);
}


##################################################################
########################## Mirc_Text_Format #########################
##################################################################
# Format from saving MIRC buffer.
sub Mirc_Text_Format
{
die if @_ != 1;
my ($all) = @_;
# Join continued lines:
$all =~ s/\n\ \ //g;
# Count the number of recognized lines
my @lines = split(/\n/, $all);
my $nLines = scalar(@lines);
my $n = 0;
my $namePattern = '([\\w\\-]([\\w\\d\\-]*))';
# First line may be empty
if (@lines && &Trim($lines[0]) eq "")
	{
	$n++;
	shift @lines;
	}
# Second line may be:
#	Start of &t-and-s buffer: Fri Apr 16 21:44:19 2004
if (@lines && $lines[0] =~ m/\AStart of \S+ buffer/)
	{
	$n++;
	shift @lines;
	}
# Last line may be:
#	End of &t-and-s buffer    Fri Apr 16 21:44:19 2004
if (@lines && $lines[@lines-1] =~ m/\AEnd of \S+ buffer/)
	{
	$n++;
	pop @lines;
	}
# Count remaining lines that look reasonable
my @loggedLines = ();
foreach my $line (@lines)
	{
	# * unlogged comment (delete)
	if ($line =~ m/\A(\s?)(\s?)(\s?)\*/) { $n++; $line = ""; }
	# <ericn> Discussion on how to progress
	elsif ($line =~ m/\A\<$namePattern\>\s/i) { $n++; }
	else	{
		# warn "MIRC not match: $line\n";
		}
	# warn "LINE: $line\n";
	push(@loggedLines, $line) if $line =~ m/\S/;
	}
my $score = $n / $nLines;
# warn "Mirc_Text_Format n: $n nLines: $nLines score: $score\n";
$all = join("\n", @loggedLines) . "\n";
# Artificially downgrade the score, so that Normalized_Format will win
# if the format is already normalized
$score = $score * 0.99;
return($score, $all);
}

##################################################################
########################## Irssi_ISO8601_Log_Text_Format #########################
##################################################################
# Example: http://lists.w3.org/Archives/Public/www-archive/2004Jan/att-0003/ExampleFormat-NormalizerHugoLogText.txt
# See also http://wiki.irssi.org/cgi-bin/twiki/view/Irssi/WindowLogging
sub Irssi_ISO8601_Log_Text_Format
{
die if @_ != 1;
my ($all) = @_;
# Join continued lines:
$all =~ s/\n\ \ //g;
# Count the number of recognized lines
my @lines = split(/\n/, $all);
my $nLines = scalar(@lines);
my $n = 0; # Number of lines of recognized format.
my $namePattern = '([\\w\\-]([\\w\\d\\-\\.]*))';
# 2003-12-18T15:26:57-0500 
my $datePattern = '(\d\d\d\d\-(\ |\d)\d\-(\ |\d)\d)';	# 3 parens
my $timePattern = '((\s|\d)\d\:(\s|\d)\d\:(\s|\d)\d)';	# 4 parens
my $hourOffsetPattern = '((( |\-|\+)\d\d\d\d)?)';	# 3 parens
my $timestampPattern = $datePattern . "T" . $timePattern . $hourOffsetPattern;
# warn "timestampPattern: $timestampPattern namePattern: $namePattern\n";
my @linesOut = ();
while (@lines)
	{
	my $line = shift @lines;
	# 20:41:27 <ericn> Review of minutes 
	if (0) {}
	# Keep normal lines:
	# 2003-12-18T15:27:36-0500 <hugo> Hello.
	elsif ($line =~ s/\A$timestampPattern\s+(\<$namePattern\>)/$11/i)
		{ $n++; push(@linesOut, $line); }
	# Also keep comment lines.  They'll be removed later.
	# 2003-12-18T16:56:06-0500  * RRSAgent records action 4
	elsif ($line =~ s/\A$timestampPattern\s+(\*)/$11/i)
		{ $n++; push(@linesOut, $line); }
	# Recognize, but discard:
	# 2003-12-18T15:26:57-0500 !mcclure.w3.org hugo invited Zakim into channel #ws-arch.
	elsif ($line =~ m/\A$timestampPattern\s+\!/i)
		{ $n++; } 
	# Recognize, but discard:
	# 2003-12-18T15:27:30-0500 -!- dbooth [dbooth@18.29.0.30] has joined #ws-arch
	elsif ($line =~ m/\A$timestampPattern\s+\-\!\-/i)
		{ $n++; } 
	else	{
		# warn "UNRECOGNIZED LINE: $line\n";
		push(@linesOut, $line); # Keep unrecognized line
		}
	# warn "LINE: $line\n";
	}
$all = "\n" . join("\n", @linesOut) . "\n";
# warn "Irssi_ISO8601_Log_Text_Format n matches: $n\n";
my $score = $n / $nLines;
return($score, $all);
}

##################################################################
########################## RRSAgent_Text_Format #########################
##################################################################
# Example: http://www.w3.org/2003/03/03-ws-desc-irc.txt
sub RRSAgent_Text_Format
{
die if @_ != 1;
my ($all) = @_;
# Join continued lines:
$all =~ s/\n\ \ //g;
# Count the number of recognized lines
my @lines = split(/\n/, $all);
my $n = 0;
my $namePattern = '([\\w\\-]([\\w\\d\\-]*))';
my $timePattern = '((\s|\d)\d\:(\s|\d)\d\:(\s|\d)\d)';
foreach my $line (@lines)
	{
	# 20:41:27 <ericn> Review of minutes 
	$n++ if $line =~ s/\A$timePattern\s+(\<$namePattern\>\s)/$5/i;
	# warn "LINE: $line\n";
	}
$all = "\n" . join("\n", @lines) . "\n";
# warn "RRSAgent_Text_Format n matches: $n\n";
my $score = $n / @lines;
return($score, $all);
}

##################################################################
########################## RRSAgent_HTML_Format #########################
##################################################################
# Example: http://www.w3.org/2003/03/03-ws-desc-irc.html
sub RRSAgent_HTML_Format
{
die if @_ != 1;
my ($all) = @_;
my @lines = split(/\n/, $all);
my $n = 0;
my $namePattern = '([\\w\\-]([\\w\\d\\-\\.]*))';
my $timePattern = '((\s|\d)\d\:(\s|\d)\d\:(\s|\d)\d)';
foreach my $line (@lines)
	{
	# <dt id="T14-35-34">14:35:34 [dbooth]</dt><dd>Gudge: why not sufficient?</dd>
	if ($line =~ s/\A\<dt\s+id\=\"($namePattern)\"\>$timePattern\s+\[($namePattern)\]\<\/dt\>\s*\<dd\>(.*)\<\/dd\>\s*\Z/\<$8\> $11/i)
		{
		$n++;
		# warn "MATCHED: $line\n";
		}
	else 	{ 
		# warn "NO match: $line\n"; 
		}
	}
$all = "\n" . join("\n", @lines) . "\n";
# warn "RRSAgent_HTML_Format n matches: $n\n";
my $score = $n / @lines;
# Unescape &entity;
$all =~ s/\&amp\;/\&/g;
$all =~ s/\&lt\;/\</g;
$all =~ s/\&gt\;/\>/g;
$all =~ s/\&quot\;/\"/g;
return($score, $all);
}

##################################################################
########################## RRSAgent_Visible_HTML_Text_Paste_Format #########################
##################################################################
# This is for the format that is visible in the browser when RRSAgent's HTML
# is displayed.  I.e., when you view the (HTML) document in a browser, and 
# then copy and paste the text from the browser window, it discards
# the HTML code and copies only the displayed text.
# Example: http://lists.w3.org/Archives/Public/www-archive/2004Jan/att-0002/ExampleFormat-RRSAgent_Visible_HTML_Text_Paste_Format.txt
sub RRSAgent_Visible_HTML_Text_Paste_Format
{
die if @_ != 1;
my ($all) = @_;
my @lines = split(/\n/, $all);
my $nLines = scalar(@lines);
my $n = 0;
my $namePattern = '([\\w\\-]([\\w\\d\\-]*))';
my $timePattern = '((\s|\d)\d\:(\s|\d)\d\:(\s|\d)\d)';
my $done = "";
# while($all =~ s/\A((.*\n)(.*\n))//)	# Grab next two lines
my $i = 0;
while ($i < (@lines-1))
	{
	# my $linePair = $1;
	my $line1 = &Trim($lines[$i]);
	my $line2 = &Trim($lines[$i+1]);
	# This format uses line pairs:
	# 	14:43:30 [Arthur]
	# 	If it's abstract, it goes into portType 
	# if ($linePair =~ s/\A($timePattern)\s+\[($namePattern)\][\ \t]*\n/\<$6\> /i)
	my $name = "";
	if ($line1 =~ m/\A($timePattern)\s+\[($namePattern)\]\Z/
		&& ($name = $6)	# Assignment!  Save that value!
		&& $line2 !~ m/\A($timePattern)\s+\[($namePattern)\]/i)
		{
		# warn "MATCH: name: $name line2: $line2\n";
		$done .= "<$name> $line2\n";
		$n += 2;
		$i++;
		}
	elsif ($line1 eq ""
		|| $line1 eq "Timestamps are in UTC."
		|| $line1 =~ m/\AIRC log of /i) 
		{ 
		# warn "IGNORING: line: $lines[$i]\n";
		$n++; 
		}
	else	{
		# warn "NO match: line: $lines[$i]\n";
		$done .= $lines[$i] . "\n";
		}
	$i++;
	}
$done .= $lines[$i] . "\n" if $i < @lines; # Remaining line
$all = $done;
# warn "RRSAgent_Visible_HTML_Text_Paste_Format n matches: $n\n";
my $score = $n / $nLines;
# die "Score: $score n: $n nLines: $nLines\n";
return($score, $all);
}

##################################################################
########################## Yahoo_IM_Format #########################
##################################################################
sub Yahoo_IM_Format
{
die if @_ != 1;
my ($all) = @_;
my @lines = split(/\n/, $all);
my $n = 0;
my $namePattern = '([\\w\\-]([\\w\\d\\-]*))';
foreach my $line (@lines)
	{
	$n++ if $line =~ s/\A($namePattern)\:\s/\<$1\> /i;
	# warn "LINE: $line\n";
	}
$all = "\n" . join("\n", @lines) . "\n";
# warn "Yahoo_IM_Format n matches: $n\n";
my $score = $n / @lines;
return($score, $all);
}

##################################################################
########################## Plain_Text_Format #########################
##################################################################
# This is just a plain text file of notes made by the scribe.
# This format does NOT use timestamps, nor does it use <speakerName>
# at the beginning of each line.  It does still use the "dbooth: ..."
# convention to indicate what someone said.
sub Plain_Text_Format
{
die if @_ != 1;
my ($all) = @_;
# Join continued lines:
# Count the number of recognized lines
my @lines = split(/\n/, $all);
my $n = 0;
my $timePattern = '((\s|\d)\d\:(\s|\d)\d\:(\s|\d)\d)';
my $namePattern = '([\\w\\-]([\\w\\d\\-\\.]*))';
for (my $i=0; $i<@lines; $i++)
	{
	# Lines should NOT have timestamps:
	# 	20:41:27 <ericn> Review of minutes 
	next if $lines[$i] =~ m/$timePattern\s+/i;
	# Lines should NOT contain <speakerName>:
	# 	<ericn> Review of minutes 
	next if $lines[$i] =~ m/(\<$namePattern\>\s)/i;
	# Line should NOT have [name] unless it pertains to an action item.
	# Check the current line and previous line for the word ACTION,
	# because the action status [PENDING] could follow the ACTION line.
	next if $lines[$i] =~ m/(\[$namePattern\]\s)/i
		&&  $lines[$i] !~ m/\bACTION\b/i
		&&  ($i == 0 || ($lines[$i] !~ m/\bACTION\b/i));
	# warn "LINE: $lines[$i]\n";
	$n++;
	}
# Now add "<scribe> " to the beginning of each line, to make it like
# the standard format.
for (my $i=0; $i<@lines; $i++)
	{
	$lines[$i] = "<scribe> " . $lines[$i];
	}
$all = "\n" . join("\n", @lines) . "\n";
# warn "Plain_Text_Format n matches: $n\n";
my $score = $n / @lines;
# Artificially downgrade the score, so that more specific formats
# like Yahoo_IM_Format will win if possible:
$score = $score * 0.95;
return($score, $all);
}

##################################################################
########################## Normalized_Format #########################
##################################################################
# Already normalized.  No-op.
sub Normalized_Format
{
die if @_ != 1;
my ($all) = @_;
# Count the number of recognized lines
my @lines = split(/\n/, $all);
my $n = 0;
my $namePattern = '([\\w\\-]([\\w\\d\\-]*))';
my $timePattern = '((\s|\d)\d\:(\s|\d)\d\:(\s|\d)\d)';
foreach my $line (@lines)
	{
	# <ericn> Review of minutes 
	$n++ if $line =~ m/\A(\<$namePattern\>\s)/i;
	# warn "LINE: $line\n";
	}
# No change to $all
my $score = $n / @lines;
return($score, $all);
}


##################################################################
########################## ProbablyUsesImplicitContinuations #########################
##################################################################
# Guess whether the input probably uses implicit continuation lines.
# The implicit continuation style is like:
# 	<dbooth> Amy: Now is the time
# 	<dbooth> for all good men and women
# 	<dbooth> to come to the aid
# 	<dbooth> of their party.
# Note that there is no extra space setting off the continuation lines.
# This style is ambiguous, because we can't distinguish between the
# continuation of the previous speaker's statement and a new statement made
# by the scribe.
#
# The <dbooth>'s should have already been changed to <scribe> prior 
# to calling this function.
sub ProbablyUsesImplicitContinuations
{
die if @_ != 1;
my ($all) = @_;
$all = &IgnoreGarbage($all);
my @lines = split(/\n/, $all);
my @t = @lines;
# Blank lines:
@t = grep {!m/\A\s*\Z/} @t;
# Only consider scribe statements
# 	<scribe> whatever
@t = grep {m/\A\<scribe\>/i} @t;
# Don't count action lines
# 	<dbooth> [DONE] ACTION: ...
@t = grep {!m/\bACTION\b/i} @t;
# Don't count empty statements
# 	<dbooth> 
# @t = grep {!m/\A\<[a-zA-Z0-9\-_\.]+\>\s*\Z/} @t;
@t = grep {!m/\A\<scribe\>\s*\Z/i} @t;
my $nTotal = scalar(@t);
 # 	<dbooth> Amy: Now is the time (EXPLICIT SPEAKER)
 # @t = grep {!m/\A\<[a-zA-Z0-9\-_\.]+\>(\s?\s?)[a-zA-Z0-9\-_\.]+\s*\:/i} @t;
 @t = grep {!m/\A\<scribe\>(\s?\s?)[a-zA-Z0-9\-_\.]+\s*\:/i} @t;
my $nSpeaker = $nTotal - scalar(@t);
 # 	<dbooth>  for all good men and women  (EXPLICIT CONTINUATION)
 # @t = grep {!m/\A\<[a-zA-Z0-9\-_\.]+\>(\s\s\s*)/} @t;
 @t = grep {!m/\A\<scribe\>(\s\s\s*)/i} @t;
 # 	<dbooth> ... for all good men and women  (EXPLICIT CONTINUATION)
 # @t = grep {!m/\A\<[a-zA-Z0-9\-_\.]+\>(\s*)\.\./} @t;
 @t = grep {!m/\A\<scribe\>(\s*)\.\./i} @t;
my $nExpCont = $nTotal - ($nSpeaker + scalar(@t));
 # Remaining lines are potentially implicit continuation lines.
my $nPossCont = scalar(@t);
die if $nPossCont + $nExpCont + $nSpeaker != $nTotal;
# warn "nTotal: $nTotal nSpeaker: $nSpeaker nExpCont: $nExpCont nPossCont: $nPossCont\n";
# warn "Possible continuations: ", join("\n", @t), "\n\n";
# Guess the format
my $result = 0;
if ($nPossCont == 0)
	{
	$result = 0;
	}
# Mostly explicit speaker lines?
elsif ($nSpeaker/$nTotal >= 0.8)
	{
	if ($nExpCont/$nPossCont < 0.2) { $result = 1; }
	else { $result = 0; }
	}
elsif ($nExpCont/$nPossCont < 0.05) { $result = 1; }
# warn "ProbablyUsesImplicitContinuations returning: $result\n";
return $result;
}

##################################################################
########################## ExpandImplicitContinuations #########################
##################################################################
# NOTE: This should be called AFTER action item processing, so that "ACTION"
# is already at the beginning of the line: 
#	<scribe> ACTION DONE: ...
# instead of:
#	<scribe> DONE ACTION: ...
# Some of the possibilities handled:
# 	<scribe> ACTION: ... 
# 	<scribe>Amy: Now is the time (typo: missing space)
# 	<scribe>  for all good men and women (explicit continuation)
# 	<scribe> Joe: Now is the time (new speaker)
# 	<scribe>  for all good men and women
# 	<scribe>  Mary: Now is the time (typo: extra space)
# 	<scribe>  for all good men and women (explicit continuation)
# 	<scribe> Frank: Now is the time (typo: extra space)
# 	<scribe> for all good men and women (IMPLICIT continuation)
#	<scribe> Scores were: (normal statement)
# 	<scribe>   Red: 4  (tabular data; continuation)
sub ExpandImplicitContinuations
{
die if @_ != 1;
my ($all) = @_;
my @lines = split(/\n/, $all);
my $inContinuation = 0;
for (my $i=0; $i<@lines; $i++)
	{
	# warn "LINE: $lines[$i]\n";
	# Skip blank lines:
	next if ($lines[$i] =~ m/\A\s*\Z/);
	# Skip lines not starting with <scribe>:
	next if ($lines[$i] !~ m/\A\<scribe\>(\s*)/i);
	# Line starts with <scribe>
	my $spaces = $1;
	my $rest = $';
	$spaces =~ s/\A ?\t/  \t/; # Initial tab forces continuation
	# Explicit continuation already:
	# 	<scribe> Amy: ... for all good men and women
	next if ($rest =~ m/\A\s*\.\./);
	# <scribe> ACTION: ...
	if ($rest =~ m/\AACTION\b/i)
		{
		$inContinuation = 0;
		next;
		}
	# <scribe>   Red: 4
	# More than one extra blank?  
	if ($inContinuation && length($spaces) > 2)
		{
		# Must be continuation of formatted text (such as a table).
		# Do nothing, because leading blank already means continuation.
		# (Though $spaces may have changed slightly if there was a tab.)
		$lines[$i] = "<scribe>$spaces$rest";
		next;
		}
	# 	<scribe> Amy: Now is the time
	# 	<scribe> ACTION: ...
	if ($rest =~ m/\A([a-zA-Z0-9\-_\.]+)( ?):/i)
		{
		# Not a continuation line.  Either new speaker or stop word.
		my $speaker = $1;
		my $newRest = $';
		$lines[$i] = "<scribe> $speaker\:$newRest";
		# New speaker starts a statement.
		# Stop word is a non-speaker, and thus terminates 
		# a continuing statement.
		my $lcSpeaker = &LC($speaker);
		$inStatement = $lcSpeaker eq "chair" 
				|| $lcSpeaker eq "scribe"
				|| !exists($stopList{$lcSpeaker});
		next;
		}
	# Exactly one extra blank?  
	# <scribe>  for all good men and women
	next if (length($spaces) == 2); # Already a continuation line
	# Otherwise it's a continuation if we're $inStatement
	if ($inStatement)
		{
		# <scribe> for all good men and women
		# Implicit continuation line!  Add leading blank:
		# warn "Reformatting implicit continuation line: <scribe>  $rest\n";
		$lines[$i] = "<scribe>  $rest";
		}
	}
$all = "\n" . join("\n", @lines) . "\n";
return($all);
}

##################################################################
##################### GetTemplate ####################
##################################################################
sub GetTemplate
{
@_ == 1 || die;
my ($templateFile) = @_;
open($templateFile,"<$templateFile") || return "";
my $template = join("",<$templateFile>);
$template =~ s/\r//g;
close($templateFile);
return $template;
}

##################################################################
######################## GetDate ####################
##################################################################
# Grab date from $all or IRC log name or default to today's date.
sub GetDate
{
@_ == 3 || die;
my ($all, $namePattern, $logURL) = @_;
my @days = qw(Sun Mon Tue Wed Thu Fri Sat); 
@days == 7 || die;
my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
@months == 12 || die;
my %monthNumbers = map {($months[$_], $_+1)} (0 .. 11);
# warn "GetDate monthNumbers: ",join(" ",%monthNumbers),"\n";
my @date = ();
# Look for Date: 12 Sep 2002
if ($all =~ s/\n\<$namePattern\>\s*(Date)\s*\:\s*(.*)\n/\n/i)
	{
	# Parse date from input.
	# I should have used a library function for this, but I wrote
	# this without net access, so I couldn't get one.
	my $d = &Trim($4);
	warn "Found Date: $d\n";
	my @words = split(/\s+/, $d);
	die "ERROR: Date not understood: $d\n" if @words != 3;
	my ($mday, $tmon, $year) = @words;
	exists($monthNumbers{$tmon}) || die;
	my $mon = $monthNumbers{$tmon};
	($mon > 0 && $mon < 13) || die;
	($mday > 0 && $mday < 32) || die;
	($year > 2000 && $year < 2100) || die;
	my $day0 = sprintf("%0d", $mday);
	my $mon0 = sprintf("%0d", $mon);
	@date = ($day0, $mon0, $year, $tmon);
	}
# Figure out date from IRC log name:
elsif ($logURL =~ m/\Ahttp\:\/\/(www\.)?w3\.org\/(\d+)\/(\d+)\/(\d+).+\-irc/i)
	{
	my $year = $2;
	my $mon = $3;
	my $mday = $4;
	($mon > 0 && $mon < 13) || die;
	($year > 2000 && $year < 2100) || die;
	($mday > 0 && $mday < 32) || die;
	my $day0 = sprintf("%0d", $mday);
	my $mon0 = sprintf("%0d", $mon);
	@date = ($day0, $mon0, $year, $months[$mon-1]);
	warn "Got date from IRC log name: $day0 " . $months[$mon-1] . " $year\n";
	}
else
	{
	warn "\nWARNING: No date found!  Assuming today.  (Hint: Specify\n";
	warn "the IRC log, and the date will be determined from that.)\n";
	warn "Or specify the date like this:\n";
	warn "<dbooth> Date: 12 Sep 2002\n\n";
	# Assume today's date by default.
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
	$mon++;	# put in range [1..12] instead of [0..11].
	($mon > 0 && $mon < 13) || die;
	$year += 1900;
	($year > 2000 && $year < 2100) || die;
	($mday > 0 && $mday < 32) || die;
	my $day0 = sprintf("%0d", $mday);
	my $mon0 = sprintf("%0d", $mon);
	@date = ($day0, $mon0, $year, $months[$mon-1]);
	}
# warn "GetDate Returning date info: @date\n";
return @date;
}



##################################################################
###################### GetNames ######################
##################################################################
# Look for people in IRC log.
sub GetNames
{
@_ == 1 || die;
my($all) = @_;

# Some important data/constants:
my @rooms = qw(MIT308 MIT531 Stata531 SophiaSofa);

my @stopList = qw(a q on Re items Zakim Topic muted and agenda Regrets http the
	RRSAgent Loggy Zakim2 ACTION Chair Meeting DONE PENDING WITHDRAWN
	Scribe 00AM 00PM P IRC Topics Keio DROPPED ger-logger
	yes no abstain Consensus Participants Question RESOLVED strategy
	AGREED Date queue no one in XachBot got it WARNING Present Agenda);
@stopList = (@stopList, @rooms);
@stopList = map {tr/A-Z/a-z/; $_} @stopList;	# Make stopList lower case
my %stopList = map {($_,$_)} @stopList;

# Easier pattern matching:
$all = "\n" . $all . "\n";

# Now start collecting names.
my %names =  ();
my $t; # Temp

# 	  ...something.html Simon's two minutes
$t = $all;
my $namePattern = '([\\w\\-]([\\w\\d\\-]*))';
# warn "namePattern: $namePattern\n";
while($t =~ s/\b($namePattern)\'s\s+(2|two)\s+ minutes/ /i)
	{
	my $n = $1;
	$names{$n} = $n;
	}

#	<dbooth> MC: I have integrated most of the coments i received 
$t = $all;
while($t =~ s/\n\<((\w|\-)+)\>(\ +)((\w|\-)+)\:/\n/i)
	{
	my $n = $4;
	next if exists($names{$n});
	# warn "Matched #	<dbooth> $n" . ": ...\n";
	$names{$n} = $n;
	}
# warn "names: ",join(" ",keys %names),"\n";

#	<Steven> Hello 
$t = $all;
while($t =~ s/\n\<((\w|\-)+)\>/\n/i)
	{
	my $n = $1;
	next if exists($names{$n});
	# warn "Matched #	<$n>\n";
	$names{$n} = $n;
	# warn "Found name: $n\n";
	}

#	Zakim sees 4 items remaining on the agenda
$t = $all;
while ($t =~ s/\n\s*((\<Zakim\>)|(\*\s*Zakim\s)).*\b(agenda|agendum)\b.*\n/\n/i)
	{
	my $match = &Trim($&);
	$match = $match;
	# warn "DELETED: $match\n";
	}

#	<Zakim> I see no one on the speaker queue
#	<Zakim> I see Hugo, Yves, Philippe on the speaker queue
#	<Zakim> I see MIT308, Ivan, Marie-Claire, Steven, Janet, EricM
#	<Zakim> On the phone I see Joseph, m3mSEA, MIT308, Marja
#	<Zakim> On IRC I see Nobu, SusanL, RRSAgent, ht, Ian, ericP
#	<Zakim> ... simonMIT, XachBot
#	<Zakim> I see MIT308, Ivan, Marie-Claire, Steven, Janet, EricM
#	<Zakim> MIT308 has Martin, Ted, Ralph, Alan, EricP, Vivien
#	<Zakim> +Carine, Yves, Hugo; got it
#
# Delete "on the speaker queue" from the ends of the lines,
# to prevent those words being mistaken for names.
while($t =~ s/(\n\<Zakim\>\s+.*)on\s+the\s+speaker\s+queue\s*\n/$1\n/i)
        {
        warn "Deleted 'on the speaker queue'\n";
        }
# Collect names
while($t =~ s/\n\<Zakim\>\s+((([\w\d\_][\w\d\_\-]+) has\s+)|(I see\s+)|(On the phone I see\s+)|(On IRC I see\s+)|(\.\.\.\s+)|(\+))(.*)\n/\n/i)
	{
	my $list = &Trim($9);
	my @names = split(/[^\w\-]+/, $list);
	@names = map {&Trim($_)} @names;
	@names = grep {$_} @names;
	# warn "Matched #       <Zakim> I see: @names\n";
	foreach my $n (@names)
		{
		next if exists($names{$n});
		$names{$n} = $n;
		}
	}

# Make the keys all lower case, so that they'll match:
%names = map {my $oldn = $_; tr/A-Z/a-z/; ($_, $names{$oldn})} keys %names;
# warn "Lower case name keys:\n";
foreach my $n (sort keys %names)
	{
	# warn "	$n	$names{$n}\n";
	}

# Eliminate non-names
foreach my $n (keys %names)
	{
	# Filter out names in stopList
	if (exists($stopList{$n})) { delete $names{$n}; }
	# Filter out names less than two chars in length:
	elsif (length($n) < 2) { delete $names{$n}; }
	# Filter out names not starting with a letter
	elsif ($names{$n} !~ m/\A[a-zA-Z]/) { delete $names{$n}; }
	}

# Make a list of unique names for the attendee list:
my %uniqNames = ();
foreach my $n (values %names)
	{
	$uniqNames{$n} = $n;
	}

# Make a list of all names seen (all variations) in lower case:
my %allNames = ();
foreach my $n (%names)
	{
	my $name = $n;
	$name =~ tr/A-Z/a-z/;
	$allNames{$name} = $name;
	}
@allNames = sort keys %allNames;
# warn "allNames: @allNames\n";
my @allNameRefs = map { \$_ } @allNames;

# Canonicalize the names in the IRC:

my @sortedUniqNames = sort values %uniqNames;
# warn "EMPTY synonyms\n" if !%synonyms;
return($all, \@allNameRefs, @sortedUniqNames);
}

##################################################################
################ LC ####################
##################################################################
# Lower Case.  Return a lower case version of the given string.
sub LC
{
@_ == 1 || die;
my ($s) = @_;	# Make a copy
$s =~ tr/A-Z/a-z/;
return $s;
}

##################################################################
################ Trim ####################
##################################################################
# Trim leading and trailing blanks from the given string.
sub Trim
{
@_ == 1 || die;
my ($s) = @_;
$s =~ s/\A\s+//;
$s =~ s/\s+\Z//;
return $s;
}

##################################################################
################ DefaultTemplate ####################
##################################################################
sub DefaultTemplate
{
return &PublicTemplate();
}

##################################################################
####################### SampleInput ##############################
##################################################################
sub SampleInput
{
my $sampleInput = <<'SampleInput-EOF'
<dbooth> Scribe: dbooth
<dbooth> Chair: Jonathan
<dbooth> Meeting: Weekly Baking Club Meeting
<hugo> Agenda: http//www.example.com/agendas/2002-12-05-agenda.html
<dbooth> Date: 05 Dec 2002
<dbooth> Topic: Review of Action Items
<Philippe> PENDING ACTION: Barbara to bake 3 pies 
<Philippe> ----
<Philippe> DONE ACTION: David to make ice cream 
<Philippe> ACTION: David to make frosting -- DONE
<Philippe> ACTION: David to make candles  *DONE*
<Philippe> ACTION: David to make world peace  *PENDING*
<dbooth> Topic: What to Eat for Dessert
<dbooth> Joseph: I think that we should all eat cake
<dbooth> ... with ice creme.
<dbooth> s/creme/cream/
<Philippe> That's a good idea
<dbooth> ACTION: dbooth to send a message to himself about action items
<dbooth> Topic: Next Week's Meeting
<Philippe> I think we should do this again next week.
<Jonathan> Sounds good to me.
<dbooth> rrsagent, where am i?
<RRSAgent> I am logging.
<RRSAgent> See http://www.w3.org/2002/11/07-ws-arch-irc#T13-59-36
SampleInput-EOF
;
return $sampleInput;
}

##################################################################
###################### GetEmbeddedTemplates ############################
##################################################################
# For new template processing.  Test with NewTemplate.htm
# Remove and return all embedded templates from given $text.  Returns:
#	$newText     -- $text after removing templates
#	%templateMap -- Map from templateNames to templates
# Returned templates also have any embedded templates removed.
sub GetEmbeddedTemplates
{
@_ == 1 || die;
my ($text) = @_;
if ($text =~ s/\<\!\-\-BEGIN\:(\w+)\-\-\>((.|\n)*?)\<\!\-\-END\:\1\-\-\>//)
	{
	my $templateName = $1;
	my $template = $2; 
	my ($newTemplate, %nestedTemplates) = &GetEmbeddedTemplates($template);
	my ($newText, %otherTemplates) = &GetEmbeddedTemplates($text);
	my %templateMap = ($templateName, $newTemplate, %nestedTemplates, %otherTemplates);
	return($newText, %templateMap);
	}
else	{
	return($text, ());
	}
}

##################################################################
###################### PublicTemplate ############################
##################################################################
sub PublicTemplate
{
my $template = <<'PublicTemplate-EOF'
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
<html>
<head>
  <title>SV_MEETING_TITLE -- SV_MEETING_DAY SV_MEETING_MONTH_ALPHA SV_MEETING_YEAR</title>
  <LINK rel="STYLESHEET" href="http://www.w3.org/StyleSheets/base.css">
  <LINK rel="STYLESHEET" href="http://www.w3.org/StyleSheets/public.css">
  <LINK rel="STYLESHEET" href="http://www.w3.org/2004/02/minutes-style.css">
  <meta content="SV_MEETING_TITLE" lang="en" name="Title">  
  <meta content="text/html; charset=iso-8859-1" http-equiv="Content-Type">
</head>

<body>
<p><a href="http://www.w3.org/"><img src="http://www.w3.org/Icons/WWW/w3c_home" alt="W3C" border="0"
height="48" width="72"></a> 

</p>

<h1>SV_MEETING_TITLE<br>
SV_MEETING_DAY SV_MEETING_MONTH_ALPHA SV_MEETING_YEAR</h1>

SV_FORMATTED_AGENDA_LINK

SV_FORMATTED_IRC_URL

<h2><a name="attendees">Attendees</a></h2>

<div class="intro">
<dl>
<dt>Present</dt>
<dd>SV_PRESENT_ATTENDEES</dd>
<dt>Regrets</dt>
<dd>SV_REGRETS</dd>
<dt>Chair</dt>
<dd>SV_MEETING_CHAIR </dd>
<dt>Scribe</dt>
<dd>SV_MEETING_SCRIBE</dd>
</dl>
</div>

<h2>Contents</h2>
<ul>
  <li><a href="#agenda">Topics</a>
	<ol>
	SV_MEETING_AGENDA
	</ol>
  </li>
  <li><a href="#ActionSummary">Summary of Action Items</a></li>
</ul>
<hr>
<div class="meeting">
SV_AGENDA_BODIES
</div>
<h2><a name="ActionSummary">Summary of Action Items</a></h2>
<!-- Action Items -->
SV_ACTION_ITEMS

<hr>

<address>
  Minutes formatted by David Booth's 
  <a href="http://dev.w3.org/cvsweb/~checkout~/2002/scribe/scribe.perl">scribe.perl SCRIBEPERL_VERSION</a> (<a href="http://dev.w3.org/cvsweb/2002/scribe/scribe.perl">CVS log</a>)<br>
  $Date$ 
</address>
</body>
</html>
PublicTemplate-EOF
;
return $template;
}

##################################################################
###################### MemberTemplate ############################
##################################################################
sub MemberTemplate
{
my $template = <<'MemberTemplate-EOF'
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
<html>
<head>
  <title>SV_MEETING_TITLE -- SV_MEETING_DAY SV_MEETING_MONTH_ALPHA SV_MEETING_YEAR</title>
  <LINK rel="STYLESHEET" href="http://www.w3.org/StyleSheets/base.css">
  <LINK rel="STYLESHEET" href="http://www.w3.org/StyleSheets/member.css">
  <link rel="STYLESHEET" href="http://www.w3.org/StyleSheets/member-minutes.css">
  <LINK rel="STYLESHEET" href="http://www.w3.org/2004/02/minutes-style.css">
  <meta content="SV_MEETING_TITLE" lang="en" name="Title">  
  <meta content="text/html; charset=iso-8859-1" http-equiv="Content-Type">
</head>

<body>
<p><a href="http://www.w3.org/"><img src="http://www.w3.org/Icons/WWW/w3c_home" alt="W3C" border="0"
height="48" width="72"></a> 
</p>

<h1>SV_MEETING_TITLE<br>
SV_MEETING_DAY SV_MEETING_MONTH_ALPHA SV_MEETING_YEAR</h1>

SV_FORMATTED_AGENDA_LINK

SV_FORMATTED_IRC_URL

<h2><a name="attendees">Attendees</a></h2>

<div class="intro">
<dl>
<dt>Present</dt>
<dd>SV_PRESENT_ATTENDEES</dd>
<dt>Regrets</dt>
<dd>SV_REGRETS</dd>
<dt>Chair</dt>
<dd>SV_MEETING_CHAIR </dd>
<dt>Scribe</dt>
<dd>SV_MEETING_SCRIBE</dd>
</dl>
</div>

<h2>Contents</h2>
<ul>
  <li><a href="#agenda">Topics</a>
	<ol>
	SV_MEETING_AGENDA
	</ol>
  </li>
  <li><a href="#ActionSummary">Summary of Action Items</a></li>
</ul>
<hr>
<div class="meeting">
SV_AGENDA_BODIES
</div>
<h2><a name="ActionSummary">Summary of Action Items</a></h2>
<!-- New Action Items -->
SV_ACTION_ITEMS

<hr>

<address>
  Minutes formatted by David Booth's 
  <a href="http://dev.w3.org/cvsweb/~checkout~/2002/scribe/scribe.perl">scribe.perl SCRIBEPERL_VERSION</a> (<a href="http://dev.w3.org/cvsweb/2002/scribe/scribe.perl">CVS log</a>)<br>
  $Date$ 
</address>
</body>
</html>
MemberTemplate-EOF
;
return $template;
}

##################################################################
###################### TeamTemplate ############################
##################################################################
sub TeamTemplate
{
my $template = <<'TeamTemplate-EOF'
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
<html>
<head>
  <title>SV_MEETING_TITLE -- SV_MEETING_DAY SV_MEETING_MONTH_ALPHA SV_MEETING_YEAR</title>
  <LINK rel="STYLESHEET" href="http://www.w3.org/StyleSheets/base.css">
  <LINK rel="STYLESHEET" href="http://www.w3.org/StyleSheets/team.css">
  <link rel="STYLESHEET" href="http://www.w3.org/StyleSheets/team-minutes.css">
  <LINK rel="STYLESHEET" href="http://www.w3.org/2004/02/minutes-style.css">
  <meta content="SV_MEETING_TITLE" lang="en" name="Title">  
  <meta content="text/html; charset=iso-8859-1" http-equiv="Content-Type">
</head>

<body>
<p><a href="http://www.w3.org/"><img src="http://www.w3.org/Icons/WWW/w3c_home" alt="W3C" border="0"
height="48" width="72"></a> 

</p>

<h1>SV_MEETING_TITLE<br>
SV_MEETING_DAY SV_MEETING_MONTH_ALPHA SV_MEETING_YEAR</h1>

SV_FORMATTED_AGENDA_LINK

SV_FORMATTED_IRC_URL

<h2><a name="attendees">Attendees</a></h2>

<div class="intro">
<dl>
<dt>Present</dt>
<dd>SV_PRESENT_ATTENDEES</dd>
<dt>Regrets</dt>
<dd>SV_REGRETS</dd>
<dt>Chair</dt>
<dd>SV_MEETING_CHAIR </dd>
<dt>Scribe</dt>
<dd>SV_MEETING_SCRIBE</dd>
</dl>
</div>

<h2>Contents</h2>
<ul>
  <li><a href="#agenda">Topics</a>
	<ol>
	SV_MEETING_AGENDA
	</ol>
  </li>
  <li><a href="#ActionSummary">Summary of Action Items</a></li>
</ul>
<hr>

<div class="meeting">
SV_AGENDA_BODIES
</div>
<h2><a name="ActionSummary">Summary of Action Items</a></h2>
<!-- New Action Items -->
SV_ACTION_ITEMS

<hr>

<address>
  Minutes formatted by David Booth's 
  <a href="http://dev.w3.org/cvsweb/~checkout~/2002/scribe/scribe.perl">scribe.perl SCRIBEPERL_VERSION</a> (<a href="http://dev.w3.org/cvsweb/2002/scribe/scribe.perl">CVS log</a>)<br>
  $Date$ 
</address>
</body>
</html>
TeamTemplate-EOF
;
return $template;
}

##################################################################
###################### MITTemplate ############################
##################################################################
sub MITTemplate
{
my $template = <<'MITTemplate-EOF'
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
<html>
<head>
  <title>SV_MEETING_TITLE -- SV_MEETING_DAY SV_MEETING_MONTH_ALPHA SV_MEETING_YEAR</title>
  <LINK rel="STYLESHEET" href="http://www.w3.org/StyleSheets/base.css">
  <LINK rel="STYLESHEET" href="http://www.w3.org/StyleSheets/team.css">
  <link rel="STYLESHEET" href="http://www.w3.org/StyleSheets/team-minutes.css">
  <LINK rel="STYLESHEET" href="http://www.w3.org/2004/02/minutes-style.css">
  <meta content="SV_MEETING_TITLE" lang="en" name="Title">  
  <meta content="text/html; charset=iso-8859-1" http-equiv="Content-Type">
</head>

<body>
<p><a href="http://www.w3.org/"><img src="http://www.w3.org/Icons/WWW/w3c_home" alt="W3C" border="0"
height="48" width="72"></a> <a href="http://www.w3.org/Team"><img width="48" height="48"
alt="W3C Team home" border="0" src="http://www.w3.org/Icons/WWW/team"></a> | <a
href="http://www.w3.org/Team/Meeting/MIT-scribes">MIT Meetings</a> 
	| <a href="http://lists.w3.org/Archives/Team/w3t-mit/SV_MEETING_YEARSV_MEETING_MONTH_ALPHA/">w3t-mit archives
</a></p>

<h1>SV_MEETING_TITLE<br>
SV_MEETING_DAY SV_MEETING_MONTH_ALPHA SV_MEETING_YEAR</h1>

SV_FORMATTED_AGENDA_LINK

SV_FORMATTED_IRC_URL

<h2><a name="attendees">Attendees</a></h2>

<div class="intro">
<dl>
<dt>Present</dt>
<dd>SV_PRESENT_ATTENDEES</dd>
<dt>Regrets</dt>
<dd>SV_REGRETS</dd>
<dt>Chair</dt>
<dd>SV_MEETING_CHAIR </dd>
<dt>Scribe</dt>
<dd>SV_MEETING_SCRIBE</dd>
</dl>
</div>

<h2>Contents</h2>
<ul>
  <li><a href="#agenda">Topics</a>
	<ol>
	SV_MEETING_AGENDA
	</ol>
  </li>
  <li><a href="#twoMinutes">Two minutes around the table</a></li>
  <li><a href="#ActionSummary">Summary of Action Items</a></li>
</ul>
<hr>

<div class="meeting">
SV_AGENDA_BODIES
</div>

<h2><a name="twoMinutes">Two minutes around the table</a></h2>

<p><em>Note to scribe: you can get a start at this section using <a
href="http://cgi.w3.org/team-bin/mit-2mins">a CGI script</a> that searches <a
href="http://lists.w3.org/Archives/Team/w3t-mit/">the w3t-mit archive</a> for
2 minute summaries and HTMLizes them.</em></p>
%%embed: http://cgi.w3.org/team-bin/mit-2mins%%

<h2><a name="ActionSummary">Summary of Action Items</a></h2>
<!-- Action Items -->
SV_ACTION_ITEMS

<hr>

<address>
  Minutes formatted by David Booth's 
  <a href="http://dev.w3.org/cvsweb/~checkout~/2002/scribe/scribe.perl">scribe.perl SCRIBEPERL_VERSION</a> (<a href="http://dev.w3.org/cvsweb/2002/scribe/scribe.perl">CVS log</a>)<br>
  $Date$ 
</address>
</body>
</html>

MITTemplate-EOF
;
return $template;
}


