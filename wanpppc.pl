package XML::Tiny;

use strict;

require Exporter;

use vars qw($VERSION @EXPORT_OK @ISA);

$VERSION = '2.06';
@EXPORT_OK = qw(parsefile);
@ISA = qw(Exporter);

# localising prevents the warningness leaking out of this module
local $^W = 1;    # can't use warnings as that's a 5.6-ism

my %regexps = (
    name => '[:_a-z][\\w:\\.-]*'
);

my $strict_entity_parsing; # mmm, global. don't worry, parsefile sets it
                           # explicitly every time

sub parsefile {
    my($arg, %params) = @_;
    my($file, $elem) = ('', { content => [] });
    local $/; # sluuuuurp

    $strict_entity_parsing = $params{strict_entity_parsing};

    if(ref($arg) eq '') { # we were passed a filename or a string
        if($arg =~ /^_TINY_XML_STRING_/) { # it's a string
            $file = substr($arg, 17);
        } else {
            local *FH;
            open(FH, $arg) || die(__PACKAGE__."::parsefile: Can't open $arg\n");
            $file = <FH>;
            close(FH);
        }
    } else { $file = <$arg>; }

    # strip any BOM
    $file =~ s/^(\xff\xfe(\x00\x00)?|(\x00\x00)?\xfe\xff|\xef\xbb\xbf)//;

    die("No elements\n") if (!defined($file) || $file =~ /^\s*$/);

    # illegal low-ASCII chars
    die("Not well-formed (Illegal low-ASCII chars found)\n") if($file =~ /[\x00-\x08\x0b\x0c\x0e-\x1f]/);

    # turn CDATA into PCDATA
    $file =~ s{<!\[CDATA\[(.*?)]]>}{
        $_ = $1.chr(0);          # this makes sure that empty CDATAs become
        s/([&<>'"])/             # the empty string and aren't just thrown away.
            $1 eq '&' ? '&amp;'  :
            $1 eq '<' ? '&lt;'   :
            $1 eq '"' ? '&quot;' :
            $1 eq "'" ? '&apos;' :
                        '&gt;'
        /eg;
        $_;
    }egs;

    die("Not well-formed (CDATA not delimited or bad comment)\n") if(
        $file =~ /]]>/ ||                          # ]]> not delimiting CDATA
        $file =~ /<!--(.*?)--->/s ||               # ---> can't end a comment
        grep { $_ && /--/ } ($file =~ /^\s+|<!--(.*?)-->|\s+$/gs) # -- in comm
    );

    # strip leading/trailing whitespace and comments (which don't nest - phew!)
    $file =~ s/^\s+|<!--(.*?)-->|\s+$//gs;
    
    # turn quoted > in attribs into &gt;
    # double- and single-quoted attrib values get done seperately
    while($file =~ s/($regexps{name}\s*=\s*"[^"]*)>([^"]*")/$1&gt;$2/gsi) {}
    while($file =~ s/($regexps{name}\s*=\s*'[^']*)>([^']*')/$1&gt;$2/gsi) {}

    if($params{fatal_declarations} && $file =~ /<!(ENTITY|DOCTYPE)/) {
        die("I can't handle this document\n");
    }

    # ignore empty tokens/whitespace tokens
    foreach my $token (grep { length && $_ !~ /^\s+$/ }
      split(/(<[^>]+>)/, $file)) {
        if(
          $token =~ /<\?$regexps{name}.*?\?>/is ||  # PI
          $token =~ /^<!(ENTITY|DOCTYPE)/i          # entity/doctype decl
        ) {
            next;
        } elsif($token =~ m!^</($regexps{name})\s*>!i) {     # close tag
            die("Not well-formed\n\tat $token\n") if($elem->{name} ne $1);
            $elem = delete $elem->{parent};
        } elsif($token =~ /^<$regexps{name}(\s[^>]*)*(\s*\/)?>/is) {   # open tag
            my($tagname, $attribs_raw) = ($token =~ m!<(\S*)(.*?)(\s*/)?>!s);
            # first make attribs into a list so we can spot duplicate keys
            my $attrib  = [
                # do double- and single- quoted attribs seperately
                $attribs_raw =~ /\s($regexps{name})\s*=\s*"([^"]*?)"/gi,
                $attribs_raw =~ /\s($regexps{name})\s*=\s*'([^']*?)'/gi
            ];
            if(@{$attrib} == 2 * keys %{{@{$attrib}}}) {
                $attrib = { @{$attrib} }
            } else { die("Not well-formed - duplicate attribute\n"); }
            
            # now trash any attribs that we *did* manage to parse and see
            # if there's anything left
            $attribs_raw =~ s/\s($regexps{name})\s*=\s*"([^"]*?)"//gi;
            $attribs_raw =~ s/\s($regexps{name})\s*=\s*'([^']*?)'//gi;
            die("Not well-formed\n$attribs_raw") if($attribs_raw =~ /\S/ || grep { /</ } values %{$attrib});

            unless($params{no_entity_parsing}) {
                foreach my $key (keys %{$attrib}) {
                    ($attrib->{$key} = _fixentities($attrib->{$key})) =~ s/\x00//g; # get rid of CDATA marker
                }
            }
            $elem = {
                content => [],
                name => $tagname,
                type => 'e',
                attrib => $attrib,
                parent => $elem
            };
            push @{$elem->{parent}->{content}}, $elem;
            # now handle self-closing tags
            if($token =~ /\s*\/>$/) {
                $elem->{name} =~ s/\/$//;
                $elem = delete $elem->{parent};
            }
        } elsif($token =~ /^</) { # some token taggish thing
            die("I can't handle this document\n\tat $token\n");
        } else {                          # ordinary content
            $token =~ s/\x00//g; # get rid of our CDATA marker
            unless($params{no_entity_parsing}) { $token = _fixentities($token); }
            push @{$elem->{content}}, { content => $token, type => 't' };
        }
    }
    die("Not well-formed (Duplicated parent)\n") if(exists($elem->{parent}));
    die("Junk after end of document\n") if($#{$elem->{content}} > 0);
    die("No elements\n") if(
        $#{$elem->{content}} == -1 || $elem->{content}->[0]->{type} ne 'e'
    );
    return $elem->{content};
}

sub _fixentities {
    my $thingy = shift;

    my $junk = ($strict_entity_parsing) ? '|.*' : '';
    $thingy =~ s/&((#(\d+|x[a-fA-F0-9]+);)|lt;|gt;|quot;|apos;|amp;$junk)/
        $3 ? (
            substr($3, 0, 1) eq 'x' ?     # using a =~ match here clobbers $3
                chr(hex(substr($3, 1))) : # so don't "fix" it!
                chr($3)
        ) :
        $1 eq 'lt;'   ? '<' :
        $1 eq 'gt;'   ? '>' :
        $1 eq 'apos;' ? "'" :
        $1 eq 'quot;' ? '"' :
        $1 eq 'amp;'  ? '&' :
                        die("Illegal ampersand or entity\n\tat $1\n")
    /ge;
    $thingy;
}

package main;

use strict;
use warnings;

use IO::Socket::INET;
use IO::Scalar;

use Data::Dumper;

# Set for display raw request/response

my $DEBUG = 0;

my %gen_wanppp_helpers = (
    AddPortMapping       => sub { 
        _gen_wanppp_action_with_params('AddPortMapping', @_) 
    },
    GetExternalIPAddress => sub { 
        _gen_wanppp_action_noparams('GetExternalIPAddress') 
    },
);

# OUT part not used but may come in handy

my %actions = (
    GetExternalIPAddress => {
        IN  => [],
        OUT => [qw(NewExternalIPAddress)],
    },
    AddPortMapping => { 
        IN  => [qw(
                NewRemoteHost NewExternalPort NewProtocol NewInternalPort 
                NewInternalClient NewEnabled NewPortMappingDescription 
                NewLeaseDuration
               )],
        OUT => [],
    },
);

# Parse command line

my $host       = shift;
my $controlurl = shift;
my $action     = shift;

_help() if !defined $host       or
           !defined $controlurl or 
           !defined $action     or 
           !exists $actions{$action};

my %args;
my $i = 0;
for (@{ $actions{$action}->{IN} }) {
    print "args{$_} = $ARGV[$i]\n" if $DEBUG;
    defined($args{$_} = $ARGV[$i]) or _help();
    ++$i;
}   

# Connect to device

my $socket = IO::Socket::INET->new(
    PeerAddr => $host,
    Proto    => 'tcp'
) or die "$!";

# Generate SOAP-HTTP request

my $request = _gen_http_request(
    POST => $controlurl,
    { 
        'Host'          => $host,
        'SOAPAction'    => "\"urn:schemas-upnp-org:service:WANPPPConnection:1#$action\"",
        'Connection'    => 'Close',
        'Cache-Control' => 'no-cache',
    }, _gen_wanppp_action($action, \%args)
);
print $request if $DEBUG;

# Send request and read response
# TODO: Set some size limit on response length

$socket->send($request) or die $!;
my $response = do { local $/; <$socket> };
print $response if $DEBUG;

# Parse response and display info about what happened

my ($code, $data, %headers) = _parse_http_response($response);
my $soap_tree = XML::Tiny::parsefile(IO::Scalar->new(\$data));

if ($code == 500) {
    _render_upnp_errmsg($soap_tree);
}
else {
    _render_upnp_action_response($action, $soap_tree)
}

#print Dumper($soap_tree);

sub _help {
    print "Usage: wanpppc.pl HOST DEVICE_CONTROL_URL ACTION [PARAMS]\n";
    print "ACTIONS: \n";

    while (my ($action, $args) = each %actions) {
        print "\t$action: ".(join ' ', @{$args->{IN}})."\n";
    }
    exit(0);
}

sub _gen_wanppp_action_with_params {
    my ($action, $opts) = @_;

    return 
    qq(<u:$action xmlns:u="urn:schemas-upnp-org:service:WANPPPConnection:1">).
    __hashref_to_xml($opts).
    "</u:$action>";
}

sub _gen_wanppp_action_noparams {
    my ($action) = @_;

    return 
    qq{<u:$action xmlns:u="urn:schemas-upnp-org:service:WANPPPConnection:1">
        </u:$action>
    };
}

sub __hashref_to_xml {
    my $hashref = shift;
    my $xml;

    while (my ($key, $val) = each %$hashref) {
        $xml .= "<$key>".(defined $val ? $val : "")."</$key>"
    }
    return $xml;
}

sub _gen_wanppp_action {
    my ($action, $params) = @_;

    my $soap = '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"'
               .'s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
               .'<s:Body>';
    $soap .= $gen_wanppp_helpers{$action}->($params);
    $soap .= "</s:Body></s:Envelope>\n";
    return $soap;
}

sub _parse_http_response { 
    my $http_packet = shift;

    my ( $headers, $data ) = split /^\r\n/m, $http_packet;
    $headers =~ s/^HTTP\/\d+\.\d+ (\d\d\d).*\r\n//; my $code = $1;
    return $code, $data, map { split /:\s*/, $_, 2 } split "\r\n", $headers;
}

sub _gen_http_request {
    my ($method, $target, $headers, $data) = @_;
    my ($header, $value);

    my $request = uc($method)." $target HTTP/1.1\r\n";
    $request .= "$header: $value\r\n"
        while (($header, $value) = each %$headers);

    if (defined $data) {
        $request .= "Content-Length: ".length($data)."\r\n\r\n$data";
    }
    else {
        $request .= "\r\n";
    }
    return $request;
}

# Code below assumes responses are valid UPnP response. See TIPS in README

sub _render_upnp_action_response {
    my ($action, $soap_tree) = @_;

    my $response = $soap_tree->[0]->{content}->[0]->{content}->[0];
    $response->{name} =~ s/^[^:]*:?(\w+)/$1/;
    print "$response->{name}: \n";
    for my $out_param (@{ $response->{content} }) {
        print "\t$out_param->{name}: $out_param->{content}->[0]->{content}\n";
    }
}

sub _render_upnp_errmsg {
    my ($soap_tree) = @_;

    for (@{ $soap_tree->[0]->{content}->[0]->{content}->[0]->{content} }) {
        if ($_->{name} eq 'detail') {
            print "UPnP Error: ";
            for my $elm (@{ $_->{content}->[0]->{content} }) {
                print "$elm->{name}=$elm->{content}->[0]->{content} "
            }
            print "\n";
        }
    }
}
