package App::Alice::HTTP;

use strict;
use warnings;

use POE qw/Component::Client::HTTP/;

POE::Component::Client::HTTP->spawn(
  Agent     => 'alice',
  Alias     => 'http',
  FollowRedirects => 2,
);

sub response_handler {
  my ($req_packet, $res_packet) = @_[ARG0, ARG1];
  my $res = $res_packet->[0];
  print STDERR "whattt\n";
}

sub streaming_response_handler {
  print STDERR "whattt\n";
  response_handler(@_);
}

1;
