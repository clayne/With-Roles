package With::Roles;
use strict;
use warnings;

our $VERSION = '0.001_000';
$VERSION =~ tr/_//d;

use Carp qw(croak);

my %COMPOSITE_NAME;
my %COMPOSITE_KEY;

my $role_suffix = 'A000';
sub _composite_name {
  my ($base, $role_base, @roles) = @_;
  my $key = join('+', $base, map join('|', @$_), @roles);
  return $COMPOSITE_NAME{$key}
    if exists $COMPOSITE_NAME{$key};

  my $new_name = $base;
  for my $roles (@roles) {
    # this creates the potential for ambiguity, but it's unlikely to happen and
    # we will keep the resulting composite
    my @short_names = @$roles;
    for (@short_names) {
      s/\A\Q$role_base\E:://
        or s/\A\Q$base\E:://;
      s/(\A:+|:+\z)/'_' x length($1)/ge;
      $_ = join '::',
        map { s/\W/_/g; $_ }
        split /::/;
    }
    $new_name .= '__WITH__' . join '__AND__', @short_names;
  }

  if ($COMPOSITE_KEY{$new_name} || length($new_name) > 252) {
    my $abbrev = substr $new_name, 0, 250 - length $role_suffix;
    $abbrev =~ s/(?<!:):$//;
    $new_name = $abbrev.'__'.$role_suffix++;
  }

  $COMPOSITE_KEY{$new_name} = $key;

  return $COMPOSITE_NAME{$key} = $new_name;
}

sub _gen {
  my ($pack, $type, @ops) = @_;
  my $e;
  {
    local $@;
    no strict 'refs';
    local *{"${pack}::${_}"}
      for qw(with extends requires has around after before);

    my $code = join('',
      "package $pack;\n",
      (defined $type ? "use $type;\n" : ()),
      (
        map "$ops[$_-1](\@{\$ops[$_]});\n",
        map $_*2+1,
        0 .. (@ops/2-1)
      ),
      "1;\n",
    );

    eval $code or $e = $@;
  }
  die $e if defined $e;
}

sub _require {
  my $package = shift;
  (my $module = "$package.pm") =~ s{::|'}{/}g;
  require $module;
}

my %BASE;
sub with::roles {
  my ($self, @roles) = @_;
  return $self
    if !@roles;

  my $base = ref $self || $self;

  my ($orig_base, @base_roles) = @{ $BASE{$base} || [$base] };

  my $role_base = $self->can('ROLE_BASE') ? $self->ROLE_BASE : $orig_base.'::Role';

  s/\A\+/${role_base}::/ for @roles;

  my @all_roles = (@base_roles, [ @roles ]);

  my $new = _composite_name($orig_base, $role_base, @all_roles);

  if (!exists $BASE{$new}) {
    my $meta;
    if (
      $INC{'Moo.pm'}
      and Moo->_accessor_maker_for($base)
    ) {
      _gen($new, 'Moo',
        extends => [ $base ],
        with => [ @roles ],
      );
    }
    elsif (
      $INC{'Moo/Role.pm'}
      and Moo::Role->is_role($base)
    ) {
      _gen($new, 'Moo::Role',
        with => [ $base ],
        with => [ @roles ],
      );
    }
    elsif (
      $INC{'Class/MOP.pm'}
      and $meta = Class::MOP::class_of($base)
      and $meta->isa('Class::MOP::Class')
    ) {
      _gen($new, 'Moose',
        extends => [ $base ],
        with => [ @roles ],
      );
    }
    elsif (
      $INC{'Class/MOP.pm'}
      and $meta = Class::MOP::class_of($base)
      and $meta->isa('Moose::Meta::Role')
    ) {
      _gen($new, 'Moose::Role',
        with => [ $base ],
        with => [ @roles ],
      );
    }
    elsif (
      defined &Mouse::Util::find_meta
      and $meta = Mouse::Util::find_meta($base)
      and $meta->isa('Mouse::Meta::Class')
    ) {
      _gen($new, 'Mouse',
        extends => [ $base ],
        with => [ @roles ],
      );
    }
    elsif (
      defined &Mouse::Util::find_meta
      and $meta = Mouse::Util::find_meta($base)
      and $meta->isa('Mouse::Meta::Role')
    ) {
      _gen($new, 'Mouse::Role',
        with => [ $base ],
        with => [ @roles ],
      );
    }
    elsif (
      $INC{'Role/Tiny.pm'}
      and Role::Tiny->is_role($base)
    ) {
      _gen($new, 'Role::Tiny',
        with => [ $base ],
        with => [ @roles ],
      );
    }
    else {
      _require($_)
        for @roles;
      if (
        $INC{'Role/Tiny.pm'}
        and !grep !Role::Tiny->is_role($_), @roles
      ) {
        no strict 'refs';
        @{"${new}::ISA"} = ($base);
        _gen($new, 'Role::Tiny::With',
          with => [ @roles ],
        );
      }
      else {
        croak "Can't determine class or role type of $base or @roles!";
      }
    }
  }

  $BASE{$new} = [$orig_base, @all_roles];

  if (ref $self) {
    # using $_[0] rather than $self, to work around how overload magic is
    # applied on perl 5.8
    return bless $_[0], $new;
  }

  return $new;
}

1;
__END__

=head1 NAME

With::Roles - Create role/class/object with composed roles

=head1 SYNOPSIS

  use With::Roles;
  # create class inheriting from My::Class, with My::Role applied
  my $class = My::Class->with::roles('My::Role');

  # create a role with My::Role, then Another::Role applied
  my $role = My::Role->with::roles('Another::Role');

  # generated role can be applied
  my $obj = My::Class->with::roles($role)->new;

  # apply role to object
  $obj->with::roles('Yet::Another::Role');

  # applies the role My::Class::Role::My::Role
  my $another_class = My::Class->with::roles('+My::Role');

=head1 DESCRIPTION

This module provides a easy to use global function that can be used on any
package to create a new package with a set of roles applied.

When used on classes, generates a subclass with the given roles applied.

When used on roles, generates a new role with the base and given roles applied.

When used on objects, applies the roles to the object and returns the object.

Compatible with L<Moose>, L<Moo>, L<Mouse>, and L<Role::Tiny> roles and classes.

The generated packages will have names based on the original classes and roles.
The exact form of the generated names should not be relied on, but should aid
with debugging.

A shorthand of C<+RoleName> can be used for roles named like
C<MyClass::Role::RoleName>.  Additional roles applied will continue to base
the name on the original class.  The package can also provide a method
C<ROLE_BASE> to return a prefix to use other than C<MyClass::Role>.

=head1 AUTHOR

haarg - Graham Knop (cpan:HAARG) <haarg@haarg.org>

=head1 CONTRIBUTORS

None so far.

=head1 COPYRIGHT

Copyright (c) 2019 the With::Roles L</AUTHOR> and L</CONTRIBUTORS>
as listed above.

=head1 LICENSE

This library is free software and may be distributed under the same terms
as perl itself. See L<https://dev.perl.org/licenses/>.

=cut
