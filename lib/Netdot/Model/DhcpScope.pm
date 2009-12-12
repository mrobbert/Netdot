package Netdot::Model::DhcpScope;

use base 'Netdot::Model';
use warnings;
use strict;

my $logger = Netdot->log->get_logger('Netdot::Model::DHCP');

=head1 NAME

Netdot::Model::DhcpScope - DHCP scope Class

=head1 SYNOPSIS


=head1 CLASS METHODS
=cut

############################################################################
=head2 search


  Argsuments: 
    Hash with search criteria
  Returns: 
    Array of DhcpScope objects or iterator (See Class::DBI)
  Examples:
    DhcpScope->search(key=>"value");
=cut

sub search {
    my ($class, @args) = @_;
    $class->isa_class_method('search');

    # Class::DBI::search() might include an extra 'options' hash ref
    # at the end.  In that case, we want to extract the 
    # field/value hash first.
    my $opts = @args % 2 ? pop @args : {}; 
    my %args = @args;

    if ( defined $args{type} ){
	if ( $args{type} =~ /\w+/ ){
	    if ( my $type = DhcpScopeType->search(name=>$args{type})->first ){
		$args{type} = $type->id;
	    }
	}
    }
    return $class->SUPER::search(%args, $opts);
}

############################################################################
=head2 insert - Insert new Scope

    Override base method to:
      - Objectify some arguments
      - Inherit failover properties from global scope if inserting subnet scope
      - Insert given attributes
      - Convert ethernet string into object

 Argsuments: 
    Hashref with following keys:
      name
      type        - DhcpScopeType name, id or object
      attributes  - A hash ref with attribute key/value pairs
  Returns: 
    DhcpScope object
  Examples:
    
=cut

sub insert {
    my ($class, $argv) = @_;
    $class->isa_class_method('insert');
    $class->throw_fatal('DhcpScope::insert: Missing required parameters')
	unless ( defined $argv->{type} );

    $class->_objectify_args($argv);
    $class->_assign_name($argv) unless $argv->{name};
    $class->_validate_args($argv);

    my $attributes = delete $argv->{attributes} if defined $argv->{attributes};

    my $scope;
    if ( $scope = $class->search(name=>$argv->{name})->first ){
	$logger->info("DhcpScope::insert: ".$argv->{name}." already exists!");
	$scope->SUPER::update($argv);
    }else{
	$scope = $class->SUPER::insert($argv);
    }

    if ( $scope->type->name eq 'subnet' ){
	# Add standard attributes
	$attributes->{'option broadcast-address'} = $argv->{ipblock}->_netaddr->broadcast->addr();
	$attributes->{'option subnet-mask'}       = $argv->{ipblock}->_netaddr->mask;
	if ( my $zone = $argv->{ipblock}->forward_zone ){
	    # Add the domain-name attribute
	    $attributes->{'option domain-name'} = $zone->name;
	}
    
	if ( int($scope->container) && $scope->container->enable_failover ){
	    my $failover_peer = $scope->container->failover_peer || 'dhcp-peer';
	    $scope->SUPER::update({enable_failover=>1, failover_peer=> $failover_peer});
	}
    }
    
    $scope->_update_attributes($attributes) if $attributes;

    return $scope;
}


############################################################################
=head2 get_containers

    This method returns all scopes which can contain other scopes.  
    Scope types that can contain other scopes are:
      global
      group
      pool
      shared-network

  Arguments:
    None
  Returns:
    Array of DhcpScope objects
  Example:
    DhcpScope->get_containers();

=cut
sub get_containers {
    my ($class) = @_;
    $class->isa_class_method('get_containers');

    my @res;

    my $q = "SELECT  dhcpscope.id
             FROM    dhcpscopetype, dhcpscope
             WHERE   dhcpscopetype.id=dhcpscope.type
                AND  (dhcpscopetype.name='global' OR
                     dhcpscopetype.name='group' OR
                     dhcpscopetype.name='pool' OR
                     dhcpscopetype.name='shared-network')
       ";

    my $dbh  = $class->db_Main();
    my $rows = $dbh->selectall_arrayref($q);

    foreach my $r ( @$rows ){
	my $id = $r->[0];
	if ( my $obj = DhcpScope->retrieve($id) ){
	    push @res, $obj;
	}
    }
    return @res;
}

=head1 INSTANCE METHODS
=cut

############################################################################
=head2 update 
    
    Override parent method to:
    - Objectify some arguments
    - Validate arguments
    - Deal with attributes

  Args: 
    Hashref
  Returns: 
    See Class::DBI
  Examples:
    $dhcp_scope->update(\%args);
=cut
sub update{
    my ($self, $argv) = @_;

    $self->_objectify_args($argv);
    $self->_assign_name($argv) unless $argv->{name};
    $self->_validate_args($argv);

    my $attributes = delete $argv->{attributes} if defined $argv->{attributes};

    if ( $self->type->name eq 'subnet' ){
	# Add standard attributes
	$attributes->{'option broadcast-address'} = $argv->{ipblock}->_netaddr->broadcast->addr();
	$attributes->{'option subnet-mask'}       = $argv->{ipblock}->_netaddr->mask;	
	if ( my $zone = $argv->{ipblock}->forward_zone ){
	    # Add the domain-name attribute
	    $attributes->{'option domain-name'} = $zone->name;
	}
    }

    my @res = $self->SUPER::update($argv);

    $self->_update_attributes($attributes) if $attributes;

    return @res;
}

############################################################################
=head2 print_to_file -  Print the config file as text (ISC DHCPD format)

  Args: 
    Hash with following keys:
    filename - (Optional)
  Returns: 
    True
  Examples:
    $scope->print_to_file();

=cut
sub print_to_file{
    my ($self, %argv) = @_;
    $self->isa_object_method('print_to_file');
    my $class = ref($self);
    my $filename;
    
    my $start = time;
    my $dir = Netdot->config->get('DHCPD_EXPORT_DIR') 
	|| $self->throw_user('DHCPD_EXPORT_DIR not defined in config file!');
    
    unless ( $filename = $argv{filename} ){
	$filename = $self->export_file;
	unless ( $filename ){
	    $logger->warn('Export filename not defined for this global scope: '. $self->name.' Using scope name.');
	    $filename = $self->name;
	}
    }
    my $path = "$dir/$filename";
    my $fh = Netdot::Exporter->open_and_lock($path);
    
    my $data = $class->_get_all_data();

    if ( !exists $data->{$self->id} ){
	$self->throw_fatal("DHCPScope::print_to_file:: Scope id". $self->id. " not found!");
    }

    print $fh "###############################################################\n";
    print $fh "# Generated by Netdot (http://netdot.uoregon.edu)\n";
    print $fh "###############################################################\n\n";

    $class->_print($fh, $self->id, $data);

    close($fh);

    my $end = time;
    $logger->info(sprintf("DHCPD Scope %s exported to %s, in %s", 
			  $self->name, $path, $class->sec2dhms($end-$start) ));
}


############################################################################
=head2 import_hosts
    
  Args: 
    text
    overwrite
  Returns: 
    Nothing
  Examples:
    $dhcp_scope->import_hosts(text=>$data);
=cut
sub import_hosts{
    my ($self, %argv) = @_;
    $self->isa_object_method('import_hosts');

    my $IPV4 = Netdot->get_ipv4_regex();
   
    $self->throw_fatal("Missing required argument: text")
	unless $argv{text};
    
    my @lines = split $/, $argv{text};

    foreach my $line ( @lines ){
	my ($mac, $ip) = split /\s+/, $line;
	$mac =~ s/\s+//g;
	$ip  =~ s/\s+//g;
	$self->throw_user("Invalid line: $line")
	    unless ($mac && $ip);
	
	$self->throw_user("Invalid mac: $mac")
	    unless ( PhysAddr->validate($mac) );

	$self->throw_user("Invalid IP: $ip")
	    unless ( $ip =~ /$IPV4/ );

	if ( $argv{overwrite} ){
	    if ( my $phys = PhysAddr->search(address=>$mac)->first ){
		foreach my $scope ( $phys->dhcp_hosts ){
		    $scope->delete();
		}
	    } 
	    if ( my $ipb = Ipblock->search(address=>$ip)->first ){
		foreach my $scope ( $ipb->dhcp_scopes ){
		    $scope->delete();
		}
	    } 
	}
    	DhcpScope->insert({
	    type      => 'host',
	    ipblock   => $ip,
	    physaddr  => $mac,
	    container => $self,
			  });
    }
}

############################################################################
=head2 get_global - Return the global scope where this scope belongs
    
  Args: 
    None
  Returns: 
    DhcpScope object
  Examples:
    $dhcp_scope->get_global();
=cut
sub get_global {
    my ($self, %argv) = @_;
    $self->isa_object_method('get_global');
    
    my $container = $self->container;

    # This does not guarantee that the result is of type "global"
    # but it's fast
    if ( int($container) == 0 ){
	return $self;
    }elsif ( ref($container) ){
	# Go recursive
	return $container->get_global();
    }elsif ( $container = DhcpScope->retrieve($container) ){
	# Why is this happening?
	$logger->debug("DhcpScope::get_global: Scope ".$self->get_label. " had to objectify container: ".$container);
	return $container->get_global();
    }else{
	$self->throw_fatal("DhcpScope::get_global: Scope ".$self->get_label. " has invalid container: ".$container);
    }
}

############################################################################
# Private methods
############################################################################

############################################################################
=head2 _objectify_args

    Convert following arguments into objects:
    - type
    - physaddr
    - ipblock
    
  Args: 
    hashref
  Returns: 
    True
  Examples:
    $class->_objectify_args($argv);

=cut
sub _objectify_args {
    my ($self, $argv) = @_;

    if ( $argv->{type} && !ref($argv->{type}) ){
	if ( $argv->{type} =~ /\D+/ ){
	    my $type = DhcpScopeType->search(name=>$argv->{type})->first;
	    $self->throw_user("DhcpScope::objectify_args: Unknown type: ".$argv->{type})
		unless $type;
	    $argv->{type} = $type;
	}elsif ( my $type = DhcpScopeType->retrieve($argv->{type}) ){
	    $argv->{type} = $type;
	}else{
	    $self->throw_user("Invalid type argument ".$argv->{type});
	}
    }

    if ( $argv->{physaddr} && !ref($argv->{physaddr}) ){
	if ( $argv->{physaddr} =~ /\D+/ ){
	    my $physaddr;
	    unless ( $physaddr = PhysAddr->search(address=>$argv->{physaddr})->first ){
		$physaddr = PhysAddr->insert({address=>$argv->{physaddr}});
	    }
	    $argv->{physaddr} = $physaddr;
	}elsif ( my $phys = PhysAddr->retrieve($argv->{physaddr}) ){
	    $argv->{physaddr} = $phys;
	}else{
	    $self->throw_user("Invalid physaddr argument ".$argv->{physaddr});
	}
    }

    if ( $argv->{container} && !ref($argv->{container}) ){
	my $container;
	if ( $argv->{container} =~ /\D+/ ){
	    if ( $container = DhcpScope->search(name=>$argv->{container})->first ){
		$argv->{container} = $container;
	    }
	}elsif ( $container = DhcpScope->retrieve($argv->{container}) ){
	    $argv->{container} = $container;
	}else{
	    $self->throw_user("Invalid container argument ".$argv->{container});
	}
    }

    if ( $argv->{ipblock} && !ref($argv->{ipblock}) ){
	if ( $argv->{ipblock} =~ /\D+/ ){
	    my $ipblock;
	    unless ( $ipblock = Ipblock->search(address=>$argv->{ipblock})->first ){
		$ipblock = Ipblock->insert({address=>$argv->{ipblock}});
		if ( $ipblock->is_address ){
		    $ipblock->update({status=>'Static'});
		}else{
		    $ipblock->update({status=>'Subnet'});
		}
	    }
	    $argv->{ipblock} = $ipblock;
	}elsif ( my $ipb = Ipblock->retrieve($argv->{ipblock}) ){
		$argv->{ipblock} = $ipb;
	}else{
	    $self->throw_user("Invalid ipblock argument ".$argv->{ipblock});
	}
    }
    1;
}

############################################################################
=head2 _validate_args

  Args: 
    hashref
  Returns: 
    True, or throws exception if validation fails
  Examples:
    $class->_validate_args($argv);

=cut
sub _validate_args {
    my ($self, $argv) = @_;
    
    my %fields;
    foreach my $field ( qw(name type physaddr ipblock container) ){
	if ( ref($self) ){
	    $fields{$field} = $self->$field;
	}
	# Overrides current value with given argument
	$fields{$field} = $argv->{$field} if exists $argv->{$field};
    }

    $self->throw_user("A scope name is required")
	unless ( defined $fields{name} && $fields{name} ne "" );

    $self->throw_user("$fields{name}: A scope type is required")
	unless $fields{type};

    if ( defined $fields{physaddr} && int($fields{physaddr}) != 0 && $fields{type}->name ne 'host' ){
	$self->throw_user("$fields{name}: Cannot assign physical address ($fields{physaddr}) to a non-host scope");
    }
    if ( defined $fields{ipblock} && int($fields{ipblock}) != 0 ){
	if ( ($fields{ipblock}->status->name eq 'Subnet') && $fields{type}->name ne 'subnet' ){
	    $self->throw_user("$fields{name}: Cannot assign a subnet to a non-subnet scope");
	}elsif ( ($fields{ipblock}->status->name eq 'Static') && $fields{type}->name ne 'host'  ){
	    $self->throw_user("$fields{name}: Cannot assign an IP address to a non-host scope");
	}
    }
    if ( $fields{type}->name eq 'host'){
	if ( !$fields{physaddr} || !$fields{ipblock} ){
	    $self->throw_user("$fields{name}: a host scope requires IP and Ethernet");
	}
    }

    my $type = $fields{type}->name;

    if ( exists $fields{container} && int($fields{container}) != 0 ){
	my $ctype = $fields{container}->type->name;
	$self->throw_user("$fields{name}: container scope type not defined")
	    unless defined $ctype;

	if ( $type eq 'global' ){
	    $self->throw_user("$fields{name}: a global scope cannot exist within another scope");
	}
	if ( $type eq 'host' && !($ctype eq 'global' || $ctype eq 'group') ){
	    $self->throw_user("$fields{name}: a host scope can only exist within a global or group scope");
	}
	if ( $type eq 'group' && $ctype ne 'global' ){
	    $self->throw_user("$fields{name}: a group scope can only exist within a global scope");
	}
	if ( $type eq 'subnet' && !($ctype eq 'global' || $ctype eq 'shared-network') ){
	    $self->throw_user("$fields{name}: a subnet scope can only exist within a global or shared-network scope");
	}
	if ( $type eq 'shared-network' && $ctype ne 'global' ){
	    $self->throw_user("$fields{name}: a shared-network scope can only exist within a global scope");
	}
	if ( $type eq 'pool' && !($ctype eq 'subnet' || $ctype eq 'shared-network') ){
	    $self->throw_user("$fields{name}: a pool scope can only exist within a subnet or shared-network scope");
	}
	if ( ($type eq 'class' || $type eq 'subclass') && $ctype ne 'global' ){
	    $self->throw_user("$fields{name}: a class or subclass scope can only exist within a global scope");
	}
    }elsif ( $type ne 'global' && $type ne 'template' ){
	$self->throw_user("$fields{name}: A container scope is required except for global and template scopes");
    }

    1;
}

############################################################################
# _print - Generate text file with scope definitions
#
# Arguments: 
#   fh     - File handle
#   id     - Scope id
#   data   - Data hash from get_all_data method
#   indent - Indent space
#
sub _print {
    my ($class, $fh, $id, $data, $indent) = @_;
    
    $indent ||= "";
    my $pindent = $indent;

    if ( !defined $fh ){
	$class->throw_fatal("Missing file handle");
    }

    if ( !defined $id ){
	$class->throw_fatal("Scope id missing");
    }

    if ( !defined $data || ref($data) ne 'HASH' ){
	$class->throw_fatal("Data missing or invalid");
    }

    if ( !defined $data->{$id}->{type} ){
	$class->throw_fatal("Scope id $id missing type");
    }

    if ( $data->{$id}->{type} ne 'global' && $data->{$id}->{type} ne 'template' ){
	print $fh $indent.$data->{$id}->{type}." ".$data->{$id}->{name}." {\n";
	$indent .= " " x 4;
    }
    
    # Print free-form text
    if ( $data->{$id}->{text} ){
	chomp $data->{$id}->{text};
	print $fh $indent.$data->{$id}->{text}, "\n" ;
    }
    
    # Print attributes
    foreach my $attr_id ( sort { $data->{$id}->{attrs}->{$a}->{name} cmp 
				     $data->{$id}->{attrs}->{$b}->{name} }
			  keys %{$data->{$id}->{attrs}} ){
	if ( $attr_id eq 'hardware ethernet' ){
	    if ( my $addr = $data->{$id}->{attrs}->{$attr_id}->{value} ){
		print $fh $indent."$attr_id ".PhysAddr->colon_address($addr).";\n";
	    }
	}elsif ( $attr_id eq 'fixed-address' ){
	    if ( my $addr = $data->{$id}->{attrs}->{$attr_id}->{value} ){
		print $fh $indent."$attr_id $addr;\n";
	    }
	}else{
	    my $name   = $data->{$id}->{attrs}->{$attr_id}->{name};
	    my $code   = $data->{$id}->{attrs}->{$attr_id}->{code};
	    my $format = $data->{$id}->{attrs}->{$attr_id}->{format};
	    my $value  = $data->{$id}->{attrs}->{$attr_id}->{value};
	    print $fh $indent.$name;
	    if ( defined $value ) {
		if ( defined $format && ($format eq 'text' || $format eq 'string') ){
		    # DHCPD requires double quotes
		    if ( $value !~ /^"(.*)"$/ ){
			$value = "\"$value\"";
		    }
		}
		print $fh " $value";
	    }
	    elsif ( $data->{$id}->{type} eq 'global' && 
		    defined $code && defined $format ){
		# Assume that user is trying to define a new option
		print $fh " $code = $format";
	    }
	    print $fh ";\n";
	    
	}
    }
    # Print "inherited" attributes from used templates
    if ( defined $data->{$id}->{templates} ){
	foreach my $template_id ( @{$data->{$id}->{templates}} ){
	    $class->_print($fh, $template_id, $data, $indent);
	}
    }

    # Create pools for subnets with dynamic addresses
    if ( $data->{$id}->{type} eq 'subnet' ){
	my $s   = DhcpScope->retrieve($id);

	my $failover_enabled = ($s->enable_failover && 
				$s->container->enable_failover)? 1 : 0;
	my $failover_peer = $s->failover_peer || 
	    $s->container->failover_peer;

	my $ipb = $s->ipblock;
	my @ranges = $ipb->get_dynamic_ranges();

	if ( @ranges ){
	    if ( $failover_enabled && $failover_peer ne ""){
		print $fh $indent."pool {\n";
		my $nindent = $indent . " " x 4;
		# This is a requirement of ISC DHCPD:
		print $fh $nindent."deny dynamic bootp clients;\n";
		print $fh $nindent."failover peer \"$failover_peer\";\n";
		foreach my $range ( @ranges ){
		    print $fh $nindent."range $range;\n";
		}
		print $fh $indent."}\n";
	    }else{
		foreach my $range ( @ranges ){
		    print $fh $indent."range $range;\n";
		}
	    }
	}
    }
    
    # Recurse for each child scope
    if ( defined $data->{$id}->{children} ){
	foreach my $child_id ( sort { $data->{$a}->{type} cmp $data->{$b}->{type} 
				      ||
				      $data->{$a}->{name} cmp $data->{$b}->{name} }
			       @{$data->{$id}->{children}} ){
	    next if $data->{$child_id}->{type} eq 'template';
	    $class->_print($fh, $child_id, $data, $indent);
	}
    }
    
    # Close scope definition
    if ( $data->{$id}->{type} ne 'global' && $data->{$id}->{type} ne 'template' ){
	$indent = $pindent;
	print $fh $indent."}\n";
    }
    
}

############################################################################
# _get_all_data - Build a hash with all necessary information to build DHCPD config
# 
# Arguments:
#   None
# Returns:
#   Hash ref
# Example:
#   DhcpScope->_get_all_data();
#
sub _get_all_data {
    my ($class) = @_;

    my %data;

    $logger->debug("DhcpScope::_get_all_data: Querying database");

    my $q = "SELECT          dhcpscope.id, dhcpscope.name, dhcpscope.text, dhcpscopetype.name, dhcpscope.container,
                             dhcpattr.id, dhcpattrname.name, dhcpattr.value, dhcpattrname.code, dhcpattrname.format,
                             physaddr.address, ipblock.address, ipblock.version
             FROM            dhcpscopetype, dhcpscope
             LEFT OUTER JOIN physaddr ON dhcpscope.physaddr=physaddr.id
             LEFT OUTER JOIN ipblock  ON dhcpscope.ipblock=ipblock.id
             LEFT OUTER JOIN (dhcpattr, dhcpattrname) ON 
                             dhcpattr.scope=dhcpscope.id AND dhcpattr.name=dhcpattrname.id
             WHERE           dhcpscopetype.id=dhcpscope.type
       ";

    my $dbh  = $class->db_Main();
    my $rows = $dbh->selectall_arrayref($q);

    $logger->debug("DhcpScope::_get_all_data: Building data structure");

    foreach my $r ( @$rows ){
	my ($scope_id, $scope_name, $scope_text, $scope_type, $scope_container, 
	    $attr_id, $attr_name, $attr_value, $attr_code, $attr_format,
	    $mac, $ip, $ipversion) = @$r;
	$data{$scope_id}{name}      = $scope_name;
	$data{$scope_id}{type}      = $scope_type;
	$data{$scope_id}{container} = $scope_container;
	$data{$scope_id}{text}      = $scope_text;
	if ( $attr_id ){
	    $data{$scope_id}{attrs}{$attr_id}{name}      = $attr_name;
	    $data{$scope_id}{attrs}{$attr_id}{code}      = $attr_code   if $attr_code;
	    $data{$scope_id}{attrs}{$attr_id}{format}    = $attr_format if $attr_format;
	    $data{$scope_id}{attrs}{$attr_id}{value}     = $attr_value  if $attr_value;
	}
	if ( $scope_type eq 'host' ){
	    $data{$scope_id}{attrs}{'hardware ethernet'}{name}  = 'hardware ethernet';
	    $data{$scope_id}{attrs}{'hardware ethernet'}{value} = $mac if $mac;
	    $data{$scope_id}{attrs}{'fixed-address'}{name}      = 'fixed-address';
	    $data{$scope_id}{attrs}{'fixed-address'}{value}     = Ipblock->int2ip($ip, $ipversion) if $ip;
	}
    }

    # Make children lists
    foreach my $id ( keys %data ){
	if ( my $parent = $data{$id}{container} ){
	    push @{$data{$parent}{children}}, $id if defined $data{$parent} ;
	}
    }

    # add  templates
    my $q2 = "SELECT scope, template FROM dhcpscopeuse";
    my $rows2  = $dbh->selectall_arrayref($q2);

    foreach my $r2 ( @$rows2 ){
	my ($id, $template) = @$r2;
	push @{$data{$id}{templates}}, $template if defined $data{$template};
    }

    return \%data;
}

############################################################################
# Assign scope name based on type and other values
sub _assign_name {
    my ($self, $argv) = @_;

    unless ( $argv->{type} ){
	if ( ref($self) ){
	    $argv->{type} = $self->type;
	}else{
	    $self->throw_fatal("DhcpScope::_assign_name: Missing required argument: type")
	}
    }

    my $name;
    if ( $argv->{type}->name eq 'host' ){
	$self->throw_fatal("DhcpScope::_assign_name: Missing ipblock object")
	    unless $argv->{ipblock};
	$name = $argv->{ipblock}->address;
    }elsif ( $argv->{type}->name eq 'subnet' ){
	$self->throw_fatal("DhcpScope::_assign_name: Missing ipblock object")
	    unless $argv->{ipblock};
	$name = $argv->{ipblock}->address." netmask ".$argv->{ipblock}->_netaddr->mask;
    }elsif ( $argv->{type}->name eq 'shared-network' ){
	$self->throw_fatal("DhcpScope::_assign_name: Missing subnet list")
	    unless $argv->{subnets};
	my $subnets = delete $argv->{subnets};
	$name = join('_', (map { $_->address } sort { $a->address_numeric <=> $b->address_numeric } @$subnets));
    }else{
	$self->throw_fatal("DhcpScope::_assign_name: Don't know how to assign name for type: ".
			   $argv->{type}->name);
    }
    $argv->{name} = $name;
}

############################################################################
# Insert or update attributes
sub _update_attributes {
    my ($self, $attributes) = @_;
    while ( my($key, $val) = each %$attributes ){
	my $attr;
	my %args = (name=>$key, scope=>$self->id);
	my $str = $key;
	$str .= ": $val" if $val;
	if ( $attr = DhcpAttr->search(%args)->first ){
	    $logger->debug("DhcpScope::_update_attributes: ".$self->get_label.": Updating DhcpAttr $str");
	    $args{value} = $val;
	    $attr->update(\%args);
	}else{
	    $logger->debug("DhcpScope::_update_attributes: ".$self->get_label.": Inserting DhcpAttr $str");
	    $args{value} = $val;
	    DhcpAttr->insert(\%args);
	}
    }
    1;
}

=head1 AUTHOR

Carlos Vicente, C<< <cvicente at ns.uoregon.edu> >>

=head1 COPYRIGHT & LICENSE

Copyright 2009 University of Oregon, all rights reserved.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTIBILITY
or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software Foundation,
Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.

=cut

#Be sure to return 1
1;

