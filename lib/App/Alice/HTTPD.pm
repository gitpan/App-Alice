package App::Alice::HTTPD;

use AnyEvent;
use AnyEvent::HTTPD;
use AnyEvent::HTTP;
use App::Alice::Stream;
use App::Alice::CommandDispatch;
use MIME::Base64;
use JSON;
use Encode;
use Any::Moose;

has 'app' => (
  is  => 'ro',
  isa => 'App::Alice',
  required => 1,
);

has 'httpd' => (
  is  => 'rw',
  isa => 'AnyEvent::HTTPD|Undef'
);

has 'streams' => (
  is  => 'rw',
  auto_deref => 1,
  isa => 'ArrayRef[App::Alice::Stream]',
  default => sub {[]},
);

sub add_stream {push @{shift->streams}, @_}
sub no_streams {@{$_[0]->streams} == 0}
sub stream_count {scalar @{$_[0]->streams}}

has 'config' => (
  is => 'ro',
  isa => 'App::Alice::Config',
  lazy => 1,
  default => sub {shift->app->config},
);

has 'ping_timer' => (
  is  => 'rw',
);

sub BUILD {
  my $self = shift;
  my $httpd = AnyEvent::HTTPD->new(
    host => $self->config->http_address,
    port => $self->config->http_port,
  );
  $httpd->reg_cb(
    '/serverconfig' => sub{$self->server_config(@_)},
    '/config'       => sub{$self->send_config(@_)},
    '/save'         => sub{$self->save_config(@_)},
    '/tabs'         => sub{$self->tab_order(@_)},
    '/view'         => sub{$self->send_index(@_)},
    '/stream'       => sub{$self->setup_stream(@_)},
    '/favicon.ico'  => sub{$self->not_found($_[1])},
    '/say'          => sub{$self->handle_message(@_)},
    '/static'       => sub{$self->handle_static(@_)},
    '/get'          => sub{$self->image_proxy(@_)},
    '/logs'         => sub{$self->send_logs(@_)},
    '/search'       => sub{$self->send_search(@_)},
    '/range'        => sub{$self->send_range(@_)},
    '/'             => sub{$self->send_index(@_)},
    'client_disconnected' => sub{$self->purge_disconnects(@_)},
    request         => sub{$self->check_authentication(@_)},
  );
  $httpd->reg_cb('' => sub{$self->not_found($_[1])});
  $self->httpd($httpd);
  $self->ping;
}

sub ping {
  my $self = shift;
  $self->ping_timer(AnyEvent->timer(
    after    => 5,
    interval => 10,
    cb       => sub {
      $self->broadcast({
        type => "action",
        event => "ping",
      });
    }
  ));
}

sub shutdown {
  my $self = shift;
  $_->close for $self->streams;
  $self->streams([]);
  $self->ping_timer(undef);
  $self->httpd(undef);
}

sub image_proxy {
  my ($self, $httpd, $req) = @_;
  $httpd->stop_request;
  my $url = $req->url;
  if (my %vars = $req->vars) {
    my $query = join "&", map {"$_=$vars{$_}"} keys %vars;
    $url .= ($query ? "?$query" : "");
  }
  $url =~ s/^\/get\///;
  http_get $url, sub {
    my ($data, $headers) = @_;
    $req->respond([$headers->{Status},$headers->{Reason},$headers,$data]);
  };
}

sub broadcast {
  my ($self, @data) = @_;
  return if $self->no_streams or !@data;
  $_->enqueue(@data) for $self->streams;
  $_->broadcast for @{$self->streams};
};

sub check_authentication {
  my ($self, $httpd, $req) = @_;
  return unless ($self->config->auth
      and ref $self->config->auth eq 'HASH'
      and $self->config->auth->{username}
      and $self->config->auth->{password});

  if (my $auth  = $req->headers->{authorization}) {
    $auth =~ s/^Basic //;
    $auth = decode_base64($auth);
    my ($user,$password)  = split(/:/, $auth);
    if ($self->config->auth->{username} eq $user &&
        $self->config->auth->{password} eq $password) {
      return;
    }
    else {
      $self->app->log(info => "auth failed");
    }
  }
  $httpd->stop_request;
  $req->respond([401, 'unauthorized', {'WWW-Authenticate' => 'Basic realm="Alice"'}]);
}

sub setup_stream {
  my ($self, $httpd, $req) = @_;
  $httpd->stop_request;
  $self->app->log(info => "opening new stream");
  my $msgid = $req->parm('msgid') || 0;
  $self->add_stream(
    App::Alice::Stream->new(
      queue   => [
        $self->app->buffered_messages($msgid),
        map({$_->nicks_action} $self->app->windows),
      ],
      request => $req,
    )
  );
}

sub purge_disconnects {
  my ($self, $host, $port) = @_;
  $self->streams([
    grep {!$_->disconnected} $self->streams
  ]);
}

sub handle_message {
  my ($self, $httpd, $req) = @_;
  $httpd->stop_request;
  my $msg  = $req->parm('msg');
  utf8::decode($msg);
  my $source = $req->parm('source');
  my $window = $self->app->get_window($source);
  if ($window) {
    for (split /\n/, $msg) {
      eval {$self->app->dispatch($_, $window) if length $_};
      if ($@) {$self->app->log(info => $@)}
    }
  }
  $req->respond([200,'ok',{'Content-Type' => 'text/plain'}, 'ok']);
}

sub handle_static {
  my ($self, $httpd, $req) = @_;
  $httpd->stop_request;
  my $file = $req->url;
  my ($ext) = ($file =~ /[^\.]\.(.+)$/);
  my $headers;
  if (-e $self->config->assetdir . "/$file") {
    open my $fh, '<', $self->config->assetdir . "/$file";
    if ($ext =~ /^(?:png|gif|jpe?g)$/i) {
      $headers = {"Content-Type" => "image/$ext"};
    }
    elsif ($ext =~ /^js$/) {
      $headers = {
        "Cache-control" => "no-cache",
        "Content-Type" => "text/javascript",
      };
    }
    elsif ($ext =~ /^css$/) {
      $headers = {
        "Cache-control" => "no-cache",
        "Content-Type" => "text/css",
      };
    }
    else {
      return $self->not_found($req);
    }
    my $content = '';
    { local $/; $content = <$fh>; }
    $req->respond([200, 'ok', $headers, $content]);
    return;
  }
  $self->not_found($req);
}

sub send_index {
  my ($self, $httpd, $req) = @_;
  $httpd->stop_request;
  my $output = $self->app->render('index');
  $req->respond([200, 'ok', {'Content-Type' => 'text/html; charset=utf-8'}, encode_utf8 $output]);
}

sub send_logs {
  my ($self, $httpd, $req) = @_;
  $httpd->stop_request;
  my $output = $self->app->render('logs');
  $req->respond([200, 'ok', {'Content-Type' => 'text/html; charset=utf-8'}, encode_utf8 $output]);
}

sub send_search {
  my ($self, $httpd, $req) = @_;
  $httpd->stop_request;
  $self->app->history->search($req->vars, sub {
    my $rows = shift;
    my $content = $self->app->render('results', $rows);
    $req->respond([200, 'ok', {'Content-Type' => 'text/html; charset=utf-8'}, encode_utf8 $content]);
  });
}

sub send_range {
  my ($self, $httpd, $req) = @_;
  $httpd->stop_request;
  my %query = $req->vars;
  $self->app->history->range($query{channel}, $query{time}, sub {
    my ($before, $after) = @_;
    $before = $self->app->render('range', $before, 'before');
    $after = $self->app->render('range', $after, 'after');
   $req->respond([200, 'ok', {'Content-Type' => 'text/html; charset=utf-8'}, to_json [$before, $after]]);
  });
}

sub send_config {
  my ($self, $httpd, $req) = @_;
  $httpd->stop_request;
  $self->app->log(info => "serving config");
  my $output = $self->app->render('servers');
  $req->respond([200, 'ok', {}, $output]);
}

sub server_config {
  my ($self, $httpd, $req) = @_;
  $httpd->stop_request;
  $self->app->log(info => "serving blank server config");
  my $name = $req->parm('name');
  $name =~ s/\s+//g;
  my $config = $self->app->render('new_server', $name);
  my $listitem = $self->app->render('server_listitem', $name);
  $req->respond([200, 'ok', {"Cache-control" => "no-cache"}, 
                to_json({config => $config, listitem => $listitem})]);
}

sub save_config {
  my ($self, $httpd, $req) = @_;
  $httpd->stop_request;
  $self->app->log(info => "saving config");
  my $new_config = {servers => {}};
  my %params = $req->vars;
  for my $name (keys %params) {
    next unless $params{$name};
    if ($name =~ /^(.+?)_(.+)/) {
      if ($2 eq "channels" or $2 eq "on_connect") {
        if (ref $params{$name} eq "ARRAY") {
          $new_config->{servers}{$1}{$2} = $params{$name};
        }
        else {
          $new_config->{servers}{$1}{$2} = [$params{$name}];
        }
      }
      else {
        $new_config->{servers}{$1}{$2} = $params{$name};
      }
    }
    else {
      $new_config->{$name} = $params{$name};
    }
  }
  $self->config->merge($new_config);
  $self->app->reload_config();
  $self->config->write;
  $req->respond([200, 'ok'])
}

sub tab_order  {
  my ($self, $httpd, $req) = @_;
  $httpd->stop_request;
  $self->app->log(debug => "updating tab order");
  my %vars = $req->vars;
  $self->app->tab_order([
    grep {defined $_} @{$vars{tabs}}
  ]);
  $req->respond([200,'ok']);
}

sub not_found  {
  my ($self, $req) = @_;
  $self->app->log(debug => "sending 404 " . $req->url);
  $req->respond([404,'not found']);
}

__PACKAGE__->meta->make_immutable;
1;
