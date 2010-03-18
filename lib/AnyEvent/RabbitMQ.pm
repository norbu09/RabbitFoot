package AnyEvent::RabbitMQ;

use strict;
use warnings;

use Data::Dumper;
use List::MoreUtils qw(none);
use File::ShareDir 'dist_file';

use AnyEvent::Handle;
use AnyEvent::Socket;

use Net::AMQP;
use Net::AMQP::Common qw(:all);

use AnyEvent::RabbitMQ::Channel;
use AnyEvent::RabbitMQ::LocalQueue;

our $VERSION = '1.01';

sub new {
    my $class = shift;
    return bless {
        verbose   => 0,
        @_,
        _is_open  => 0,
        _queue    => AnyEvent::RabbitMQ::LocalQueue->new,
        _channels => {},
    }, $class;
}

sub channels {
    my $self = shift;
    return $self->{_channels};
}

sub delete_channel {
    my $self = shift;
    my ($id) = @_;
    return delete $self->{_channels}->{$id};
}

sub load_xml_spec {
    my $self = shift;
    Net::AMQP::Protocol->load_xml_spec( shift || File::ShareDir::dist_file( 'Net-RabbitFoot', 'amqp0-8.xml' )); # die when fail in this line.
    return $self;
}

sub connect {
    my $self = shift;
    my %args = $self->_set_cbs(@_);

    if ($self->{_is_open}) {
        $args{on_failure}->('Connection has already been opened');
        return $self;
    }

    $args{on_close}        ||= sub {};
    $args{on_read_failure} ||= sub {warn @_, "\n"};
    $args{timeout}         ||= 0;

    if ($self->{verbose}) {
        warn 'connect to ', $args{host}, ':', $args{port}, '...', "\n";
    }

    $self->{_connect_guard} = AnyEvent::Socket::tcp_connect(
        $args{host},
        $args{port},
        sub {
            my $fh = shift or return $args{on_failure}->(
                'Error connecting to AMQP Server: ' . $!
            );

            $self->{_handle} = AnyEvent::Handle->new(
                fh       => $fh,
                on_error => sub {
                    my ($handle, $fatal, $message) = @_;

                    $self->{_channels} = {};
                    $self->{_is_open} = 0;
                    $self->_disconnect();
                    $args{on_close}->($message);
                },
            );
            $self->_read_loop($args{on_close}, $args{on_read_failure});
            $self->_start(%args,);
        },
        sub {
            return $args{timeout};
        },
    );

    return $self;
}

sub _read_loop {
    my ($self, $close_cb, $failure_cb,) = @_;

    return if !defined $self->{_handle}; # called on_error

    $self->{_handle}->push_read(chunk => 8, sub {
        my $data = $_[1];
        my $stack = $_[1];

        if (length($data) <= 7) {
            $failure_cb->('Broken data was received');
            @_ = ($self, $close_cb, $failure_cb,);
            goto &_read_loop;
        }

        my ($type_id, $channel, $length,) = unpack 'CnN', substr $data, 0, 7, '';
        if (!defined $type_id || !defined $channel || !defined $length) {
            $failure_cb->('Broken data was received');
            @_ = ($self, $close_cb, $failure_cb,);
            goto &_read_loop;
        }

        $self->{_handle}->push_read(chunk => $length, sub {
            $stack .= $_[1];
            my ($frame) = Net::AMQP->parse_raw_frames(\$stack);

            if ($self->{verbose}) {
                warn '[C] <-- [S] ' . Dumper($frame);
                warn '-----------', "\n";
            }

            my $id = $frame->channel;
            if (0 == $id) {
                return if !$self->_check_close_and_clean($frame, $close_cb,);
                $self->{_queue}->push($frame);
            } else {
                my $channel = $self->{_channels}->{$id};
                if (defined $channel) {
                    $channel->push_queue_or_consume($frame, $failure_cb);
                } else {
                    $failure_cb->('Unknown channel id: ' . $frame->channel);
                }
            }

            @_ = ($self, $close_cb, $failure_cb,);
            goto &_read_loop;
        });
    });

    return $self;
}

sub _check_close_and_clean {
    my $self = shift;
    my ($frame, $close_cb,) = @_;

    return 1 if !$frame->isa('Net::AMQP::Frame::Method');

    my $method_frame = $frame->method_frame;
    return 1 if !$method_frame->isa('Net::AMQP::Protocol::Connection::Close');

    $self->_push_write(Net::AMQP::Protocol::Connection::CloseOk->new());
    $self->{_channels} = {};
    $self->{_is_open} = 0;
    $self->_disconnect();
    $close_cb->($frame);
    return;
}

sub _start {
    my $self = shift;
    my %args = @_;

    if ($self->{verbose}) {
        warn 'post header', "\n";
    }

    $self->{_handle}->push_write(Net::AMQP::Protocol->header);

    $self->_push_read_and_valid(
        'Connection::Start',
        sub {
            my $frame = shift;

            my @mechanisms = split /\s/, $frame->method_frame->mechanisms;
            return $args{on_failure}->('AMQPLAIN is not found in mechanisms')
                if none {$_ eq 'AMQPLAIN'} @mechanisms;

            my @locales = split /\s/, $frame->method_frame->locales;
            return $args{on_failure}->('en_US is not found in locales')
                if none {$_ eq 'en_US'} @locales;

            $self->_push_write(
                Net::AMQP::Protocol::Connection::StartOk->new(
                    client_properties => {
                        platform    => 'Perl',
                        product     => __PACKAGE__,
                        information => 'http://d.hatena.ne.jp/cooldaemon/',
                        version     => '1.01',
                    },
                    mechanism => 'AMQPLAIN',
                    response => {
                        LOGIN    => $args{user},
                        PASSWORD => $args{pass},
                    },
                    locale => 'en_US',
                ),
            );

            $self->_tune(%args,);
        },
        $args{on_failure},
    );

    return $self;
}

sub _tune {
    my $self = shift;
    my %args = @_;

    $self->_push_read_and_valid(
        'Connection::Tune',
        sub {
            my $frame = shift;

            $self->_push_write(
                Net::AMQP::Protocol::Connection::TuneOk->new(
                    channel_max => $frame->method_frame->channel_max,
                    frame_max   => $frame->method_frame->frame_max,
                    heartbeat   => $frame->method_frame->heartbeat,
                ),
            );

            $self->_open(%args,);
        },
        $args{on_failure},
    );

    return $self;
}

sub _open {
    my $self = shift;
    my %args = @_;

    $self->_push_write_and_read(
        'Connection::Open',
        {
            virtual_host => $args{vhost},
            capabilities => '',
            insist       => 1,
        },
        'Connection::OpenOk', 
        sub {
            $self->{_is_open} = 1;
            $args{on_success}->($self);
        },
        $args{on_failure},
    );

    return $self;
}

sub close {
    my $self = shift;
    my %args = $self->_set_cbs(@_);

    return $self if !$self->{_is_open};

    my $close_cb = sub {
        $self->_close(
            sub {
                $self->_disconnect();
                $args{on_success}->(@_);
            },
            sub {
                $self->_disconnect();
                $args{on_failure}->(@_);
            }
        );
        return $self;
    };

    if (0 == scalar keys %{$self->{_channels}}) {
        return $close_cb->();
    }

    for my $id (keys %{$self->{_channels}}) {
         $self->{_channels}->{$id}->close(
            on_success => $close_cb,
            on_failure => sub {
                $close_cb->();
                $args{on_failure}->(@_);
            },
        );
    }

    return $self;
}

sub _close {
    my $self = shift;
    my ($cb, $failure_cb,) = @_;

    return $self if !$self->{_is_open} || 0 < scalar keys %{$self->{_channels}};

    $self->_push_write_and_read(
        'Connection::Close', {}, 'Connection::CloseOk',
        $cb, $failure_cb,
    );
    $self->{_is_open} = 0;

    return $self;
}

sub _disconnect {
    my $self = shift;

    delete $self->{_handle};
    delete $self->{_connect_guard};

    return $self;
}

sub open_channel {
    my $self = shift;
    my %args = $self->_set_cbs(@_);

    return $self if !$self->_check_open($args{on_failure});

    $args{on_close} ||= sub {};

    my $id = $args{id};
    if ($id && $self->{_channels}->{$id}) {
        $args{on_failure}->("Channel id $id is already in use");
        return $self;
    }

    if (!$id) {
        for my $candidate_id (1 .. (2**16 - 1)) {
            next if defined $self->{_channels}->{$candidate_id};
            $id = $candidate_id;
            last;
        }
        if (!$id) {
            $args{on_failure}->('Ran out of channel ids');
            return $self;
        }
    }

    my $channel = AnyEvent::RabbitMQ::Channel->new(
        id         => $id,
        connection => $self,
        on_close   => $args{on_close},
    );

    $self->{_channels}->{$id} = $channel;

    $channel->open(
        on_success => sub {
            $args{on_success}->($channel);
        },
        on_failure => sub {
            $self->delete_channel($id);
            $args{on_failure}->(@_);
        },
    );

    return $self;
}

sub _push_write_and_read {
    my $self = shift;
    my ($method, $args, $exp, $cb, $failure_cb, $id,) = @_;

    $method = 'Net::AMQP::Protocol::' . $method;
    $self->_push_write(
        Net::AMQP::Frame::Method->new(
            method_frame => $method->new(%$args)
        ),
        $id,
    );

    return $self->_push_read_and_valid($exp, $cb, $failure_cb, $id,);
}

sub _push_read_and_valid {
    my $self = shift;
    my ($exp, $cb, $failure_cb, $id,) = @_;
    $exp = ref($exp) eq 'ARRAY' ? $exp : [$exp];

    my $queue;
    if (!$id) {
        $queue = $self->{_queue};
    } elsif (defined $self->{_channels}->{$id}) {
        $queue = $self->{_channels}->{$id}->queue;
    } else {
        $failure_cb->('Unknown channel id: ' . $id);
    }

    $queue->get(sub {
        my $frame = shift;

        return $failure_cb->('Received data is not method frame')
            if !$frame->isa('Net::AMQP::Frame::Method');

        my $method_frame = $frame->method_frame;
        for my $exp_elem (@$exp) {
            return $cb->($frame)
                if $method_frame->isa('Net::AMQP::Protocol::' . $exp_elem);
        }

        $failure_cb->(
              'Method is not ' . join(',', @$exp) . "\n"
            . 'Method was ' . ref $method_frame
        );
    });
}

sub _push_write {
    my $self = shift;
    my ($output, $id,) = @_;

    if ($output->isa('Net::AMQP::Protocol::Base')) {
        $output = $output->frame_wrap;
    }
    $output->channel($id || 0);

    if ($self->{verbose}) {
        warn '[C] --> [S] ', Dumper($output);
    }

    $self->{_handle}->push_write($output->to_raw_frame());
    return;
}

sub _set_cbs {
    my $self = shift;
    my %args = @_;

    $args{on_success} ||= sub {};
    $args{on_failure} ||= sub {die @_};

    return %args;
}

sub _check_open {
    my $self = shift;
    my ($failure_cb) = @_;

    return 1 if $self->{_is_open};

    $failure_cb->('Connection has already been closed');
    return 0;
}

sub DESTROY {
    my $self = shift;
    $self->close();
    return;
}

1;
__END__

=head1 NAME

AnyEvent::RabbitMQ - An asynchronous and multi channel Perl AMQP client.

=head1 SYNOPSIS

  use AnyEvent::RabbitMQ;

  my $cv = AnyEvent->condvar;

  my $ar = AnyEvent::RabbitMQ->new->load_xml_spec->connect(
      host       => 'localhosti',
      port       => 5672,
      user       => 'guest',
      port       => 'guest',
      vhost      => '/',
      timeout    => 1,
      on_success => sub {
          $ar->open_channel(
              on_success => sub {
                  my $channel = shift;
                  $channel->declare_exchange(
                      exchange   => 'test_exchange',
                      on_success => sub {
                          $cv->send('Declared exchange');
                      },
                      on_failure => $cv,
                  );
              },
              on_failure => $cv,
              on_close   => sub {
                  my $method_frame = shift->method_frame;
                  die $method_frame->reply_code, $method_frame->reply_text;
              }
          );
      },
      on_failure => $cv,
      on_read_failure => sub {die @_},
      on_close   => sub {
          my $method_frame = shift->method_frame;
          die $method_frame->reply_code, $method_frame->reply_text;
      },
  );

  print $cv->recv, "\n";

=head1 DESCRIPTION

AnyEvent::RabbitMQ is an AMQP(Advanced Message Queuing Protocol) client library, that is intended to allow you to interact with AMQP-compliant message brokers/servers such as RabbitMQ in an asynchronous fashion.

You can use AnyEvent::RabbitMQ to -

  * Declare and delete exchanges
  * Declare, delete, bind and unbind queues
  * Set QoS
  * Publish, consume, get, ack and recover messages
  * Select, commit and rollback transactions

AnyEvnet::RabbitMQ is known to work with RabbitMQ versions 1.7.2 and version 0-8 of the AMQP specification.

=head1 AUTHOR

Masahito Ikuta E<lt>cooldaemon@gmail.comE<gt>

=head1 SEE ALSO

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
