package npg_tracking::report::event2subscribers;

use Moose;
use namespace::autoclean;
use List::MoreUtils qw/uniq/;
use Readonly;
use Carp;

use st::api::lims;
use npg::util::mailer;

extends 'npg_tracking::report::event2lims';

our $VERSION = '0';

Readonly::Scalar my $TEMPLATE_DIR            => q[data/npg_tracking_email/templates];
Readonly::Scalar my $TEMPLATE_EXT            => q[.tt2];
Readonly::Scalar my $DEFAULT_RECIPIENT_HOST  => q[@sanger.ac.uk];
Readonly::Scalar my $DEFAULT_AUTHOR          => q[srpipe];

has 'schema_mlwh' => (
  isa        => 'WTSI::DNAP::Warehouse::Schema',
  is         => 'ro',
  required   => 0,
  predicate  => '_has_schema_mlwh',
);

sub _build_lims {
  my $self = shift;

  my @lims_list = ();
  if ($self->event_entity->can('id_run')) {
    my $id_run = $self->event_entity->id_run();
    my $schema = $self->event_entity->result_source()->schema();
    my $run_row = $schema->resultset('Run')->find($id_run);
    my $ref = { id_run => $id_run };
    if ($self->event_entity->can('position')) {
      $ref->{'position'} = $self->event_entity->position();
    }
    if ($self->_has_schema_mlwh()) {
      $ref->{'id_flowcell_lims'}    = $run_row->batch_id();
      $ref->{'id_flowcell_barcode'} = $run_row->flowcell_id();
      $ref->{'driver_type'}         = 'ml_warehouse_auto';
      $ref->{'schema_mlwh'}         = $self->schema_mlwh();
    }
    # Allow to fall back on some other driver type, for
    # example, samplesheet. This will allow to test this
    # utility in the absence of WTSI::DNAP::Warehouse::Schema
    # and associated with this schema LIMs drivers.
    my $lims = st::api::lims->new($ref);
    # Explicitly forbid using the xml driver.
    if ($lims->driver_type() eq 'xml') {
      croak 'XML driver type is not allowed';
    }
    @lims_list =  $ref->{'position'} ? ($lims) : $lims->children();
  }

  return \@lims_list;
}

has '_is_instrument_event' => (
  is         => 'ro',
  required   => 0,
  isa        => 'Bool',
  lazy_build => 1,
);
sub _build__is_instrument_event {
  my $self = shift;
  my $table_name = $self->event_entity->result_source()->name();
  return $table_name =~ /^instrument/xms;
}

has 'template_name' => (
  is         => 'ro',
  required   => 0,
  isa        => 'Str',
  lazy_build => 1,
);
sub _build_template_name {
  my $self = shift;
  return $self->_is_instrument_event ? 'instrument' : 'run_or_lane2subscribers';
}

sub report_full {
  my ($self, $lims) = @_;
  my $text;
  Template->new(
    INCLUDE_PATH => [ $TEMPLATE_DIR ],
    INTERPOLATE  => 1,
    OUTPUT       => $text,
  )->process(
    $self->template_name() . $TEMPLATE_EXT,
    {
      lanes        => $lims,
      event_entity => $self->event_entity(),
    }
  );
  return $text;
}

sub report_short {
  my $self = shift;
  return $self->event_entity->summary();
}

sub report_author {
  my $self = shift;
  my $author = $ENV{'USER'} || $DEFAULT_AUTHOR;
  return $self->username2email_address($author)->[0];
}

sub usernames2email_address {
  my ($self, @users) = @_;
  my @emails = uniq
               map { $_ =~ /@/xms ? $_ : $_ . $DEFAULT_RECIPIENT_HOST}
               @users;
  @emails = sort @emails;
  return \@emails;
}

sub _subscribers {
  my $self = shift;
  my $group = $self->_is_instrument_event ? q[engineers] : q[events];
  my @subscribers = ();
  my $schema = $self->event_entity->result_set->schema;
  my $group_row = $schema->resultset('Usergroup')->search(
                  {groupname => $group, iscurrent => 1})->next();
  if (!$group_row) {
    croak "Group $group is not available in the db";
  }
  push @subscribers, map {$_->user()->username()} $group_row->user2usergroups()->all();
  return $self->usernames2email_address(@subscribers);
}

sub _build_reports {
  my $self = shift;

  my @reports = ();
  my @subscribers = $self->_subscribers();
  if (!@subscribers) {
    carp 'Nobody to send to';
  } else {
    push @reports, npg::util::mailer->new(
      from    => $self->report_author(),
      subject => $self->report_short(),
      body    => $self->report_full($self->lims()),
      to      => $self->_subscribers(),
    );
  }

  return \@reports;
}

sub emit {
  my $self = shift;
  foreach my $report (@{$self->reports}) {
    if (!$self->dry_run) {
      carp $report->{'subject'};
    } else {
      $report->mail();
    }
  }
  return;
}

1;
