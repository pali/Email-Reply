use strict;
use warnings;
package Email::Reply;
# ABSTRACT: reply to an email message

use Email::Abstract 2.01;
use Email::Address::XS;
use Email::MIME 1.82;
use Exporter 5.57 'import';

my $CLASS   = __PACKAGE__;
our @EXPORT  = qw[reply];
my $CRLF = "\x0d\x0a";

# Want to subclass and still use the functional interface?
# That's cool, just add these lines to your package:
#    use base qw[Exporter];
#    use vars qw[@EXPORT $CLASS];
#    @EXPORT = qw[reply];
#    $CLASS  = __PACKAGE__;
#    *reply  = \&Email::Reply::reply;

sub reply {
  my $reply = $CLASS->_new(@_);
  $reply->_make_headers;
  $reply->_encapsulate_message if $reply->{attach};
  $reply->_quote_body($reply->{original})
    if $reply->{quote} || $reply->{top_post};
  $reply->_post_reply if $reply->{body};
  return $reply->{message} ? $reply->_mime : $reply->_simple;
}

sub _new {
  my ($class, %args) = @_;
  my $self = {};
  $self->{original} = Email::MIME->new(Email::Abstract->as_string($args{to}));

  ($self->{from}) =
    Email::Address::XS->parse($args{from} || $self->{original}->header('To'));
  die 'invalid from address' if not $self->{from};

  # There are three headers which may give the 'to' address.
  my $addr_to_parse;
  my @headers = qw(Reply-To From Return-Path);
  my $orig = $self->{original};
  foreach (@headers) {
      my $v = $orig->header($_);
      if (defined $v and $v ne '') {
          $addr_to_parse = $v;
          last;
      }
  }
  die "did not find any of the headers: @headers" if not defined $addr_to_parse;

  # Parse it and check it succeeded.
  my (@parsed) = Email::Address::XS->parse($addr_to_parse);
  die "failed to parse address '$addr_to_parse'" if not @parsed;
  die "strange, '$addr_to_parse' parses to more than one address: @parsed" if @parsed != 1;
  $self->{to} = $parsed[0];

  $self->{attrib} = $args{attrib}
    || (($self->{to}->name || join($self->{to}->address, '<', '>')) . ' wrote:');

  $self->{prefix}   = $args{prefix} || '> ';
  $self->{top_post} = $args{top_post};
  $self->{quote}    = exists $args{quote} ? $args{quote} : 1;
  $self->{all}      = $args{all};
  $self->{quoted}   = '';
  $self->{body}     = $args{body};
  $self->{attach}   = $args{attach};
  $self->{keep_sig} = $args{keep_sig};

  return bless $self, $class;
}

sub _make_headers {
  my $self = shift;

  my @header = (From => $self->{from},);

  if (not defined $self->{to}->phrase) {
    my ($from) = Email::Address::XS->parse($self->{original}->header('From'));
    $self->{to}->phrase($from->phrase) if defined $from;
  }
  push @header, To => $self->{to}->format;

  my $subject = $self->{original}->header('Subject') || '';
  $subject = "Re: $subject" unless $subject =~ /\bRe:/i;
  push @header, Subject => $subject;

  my $msg_id = $self->{original}->header('Message-ID');
  push @header, 'In-Reply-To' => $msg_id if $msg_id;

  my $refs = $self->{original}->header('References') || $self->{original}->header('In-Reply-To');
  if ($msg_id) {
    if ($refs) {
      $refs .= ' ' . $msg_id;
    } else {
      $refs = $msg_id;
    }
  }
  push @header, References => $refs if $refs;

  if ($self->{all}) {
    my @addrs = (
      map { Email::Address::XS->parse($_) } (
        $self->{original}->header('To'),
        $self->{original}->header('Cc'),
      )
    );
    unless ($self->{self}) {
      @addrs = grep { $_->address ne $self->{from}->address } @addrs;
    }
    push @header, Cc => Email::Address::XS::format_email_addresses(@addrs);
  }

  $self->{header} = \@header;
}

sub _encapsulate_message {
  my $self = shift;
  $self->{message} = Email::MIME->create(
    attributes => { content_type => 'message/rfc822', },
    body       => $self->{original}->as_string,
  );
}

my $crlf = qr/\x0a\x0d|\x0d\x0a|\x0a|\x0d/;

sub _quote_body {
  my ($self, $part) = @_;
  return if length $self->{quoted};
  return map $self->_quote_body($_), $part->parts if $part->parts > 1;
  return if $part->content_type && $part->content_type !~ m[\btext/plain\b];

  my $body = $part->body;

  $body = ($self->_strip_sig($body) || $body)
    if !$self->{keep_sig} && $body =~ /$crlf--\s*$crlf/o;

  my ($end) = $body =~ /($crlf)/;
  $end ||= $CRLF;
  $body =~ s/[\r\n\s]+$//;
  $body = $self->_quote_orig_body($body);
  $body = "$self->{attrib}$end$body$end";

  $self->{crlf}   = $end;
  $self->{quoted} = $body;
}

# Yes, you are witnessing elitism.
sub _strip_sig { reverse +(split /$crlf\s*--$crlf/o, reverse(pop), 2)[1] }

sub _quote_orig_body {
  my ($self, $body) = @_;
  $body =~ s/($crlf)/$1$self->{prefix}/g;
  "$self->{prefix}$body";
}

sub _post_reply {
  my $self = shift;
  return $self->{reply_body} = $self->{body}
    unless length $self->{quoted};
  my @parts = (@{$self}{qw[quoted body]});
  @parts = reverse @parts if $self->{top_post};
  $self->{reply_body} = join $self->{crlf}, @parts;
}

sub _mime {
  my $self = shift;
  Email::MIME->create(
    header => $self->{header},
    parts =>
      [ Email::MIME->create(body => $self->{reply_body}), $self->{message}, ],
  );
}

sub _simple {
  my $self = shift;
  Email::Simple->create(
    header => $self->{header},
    body   => $self->{reply_body},
  );
}

1;

=head1 SYNOPSIS

  use Email::Reply;

  my $message = Email::Simple->new(join '', <>);
  my $from    = Email::Address::XS->parse($message->header('From'));
  
  my $reply   = reply to   => $message,
                      from => '"Casey West" <casey@geeknest.com>',
                      all  => 1,
                      body => <<__RESPONSE__;
  Thanks for the message, I'll be glad to explain...
  __RESPONSE__

=head1 DESCRIPTION

This software takes the hard out of generating replies to email messages.

=func reply

  my $reply   = reply to       => $message,
                      from     => '"Casey West" <casey@geeknest.com>',
                      all      => 1;
                      self     => 0,
                      attach   => 1,
                      quote    => 1,
                      top_post => 0,
                      keep_sig => 1,
                      prefix   => ': ',
                      attrib   => sprintf("From %s, typer of many words:",
                                          $from->name),
                      body     => <<__RESPONSE__;
  Thanks for the message, I'll be glad to explain the picture...
  __RESPONSE__

This function accepts a number of named parameters and returns an email
message object of type C<Email::MIME> or C<Email::Simple>, depending
on the parameters passed. Lets review those parameters now.

=begin :list

= C<to>

This required parameter is the email message you're replying to. It can
represent a number of object types, or a string containing the message.  This
value is passed directly to C<Email::Abstract> without passing go or collecting
$200 so please, read up on its available plugins for what is allowed here.

= C<from>

This optional parameter specifies an email address to use indicating the sender
of the reply message. It can be a string or an C<Email::Address::XS> object. In the
absence of this parameter, the first address found in the original message's
C<To> header is used. This may not always be what you want, so this parameter
comes highly recommended.

= C<all>

This optional parameter indicates weather or not you'd like to "Reply to All."
If true, the reply's C<Cc> header will be populated with all the addresses in
the original's C<To> and C<Cc> headers. By default, the parameter is false,
indicating "Reply to Sender."

= C<self>

This optional parameter decides weather or not an address matching the C<from>
address will be included in the list of C<all> addresses. If true, your address
will be preserved in that list if it is found. If false, as it is by default,
your address will be removed from the list. As you might expect, this parameter
is only useful if C<all> is true.

= C<attach>

This optional parameter allows for the original message, in
its entirety, to be encapsulated in a MIME part of type C<message/rfc822>.
If true, the returned object from C<reply> will be a C<Email::MIME> object
whose second part is the encapsulated message. If false, none of this happens.
By default, none of this happens.

= C<quote>

This optional parameter, which is true by default, will quote
the original message for your reply. If the original message is a MIME
message, the first C<text/plain> type part will be quoted. If it's a Simple
message, the body will be quoted. Well, that's only if you keep the
parameter true. If you don't, none of this occurs.

= C<top_post>

This optional parameter, whose use is generally discouraged, will allow top
posting when true. It will implicitly set C<quote> to true, and put your
C<body> before the quoted text. It is false by default, and you should do your
best to keep it that way.

= C<keep_sig> 

This optional parameter toggles the signature stripping mechanism. True by
default, the original quoted body will have its signature removed. When false,
the signature is left in-tact and will be quoted accordingly. This is only
useful when C<quote> is true.

= C<prefix> 

This optional parameter specifies the quoting prefix. By default, it's
C<< > >>, but you can change it by setting this parameter. Again, only useful
when C<quote> is true.

= C<attrib>

This optional parameter specifies the attribution line to add to the beginning
of quoted text. By default, the name or email address of the original sender is
used to replace C<%s> in the string, C<"%s wrote:">.  You may change that with
this parameter. No special formats, C<sprintf()> or otherwise, are provided for
your convenience. Sorry, you'll have to make due.  Like C<prefix> and
C<keep_sig>, this is only good when C<quote> is true.

= C<body>

This required parameter contains your prose, your manifesto, your reply.
Remember to spell check!

=end :list

=head1 SEE ALSO

L<Email::Abstract>,
L<Email::MIME>,
L<Email::MIME::Creator>,
L<Email::Simple::Creator>,
L<Email::Address::XS>,
L<perl>.
