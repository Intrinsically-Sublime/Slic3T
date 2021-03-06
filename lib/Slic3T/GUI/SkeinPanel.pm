package Slic3T::GUI::SkeinPanel;
use strict;
use warnings;
use utf8;

use File::Basename qw(basename dirname);
use Slic3T::Geometry qw(X Y);
use Wx qw(:sizer :progressdialog wxOK wxICON_INFORMATION wxICON_WARNING wxICON_ERROR wxICON_QUESTION
    wxOK wxCANCEL wxID_OK wxFD_OPEN wxFD_SAVE wxDEFAULT wxNORMAL);
use Wx::Event qw(EVT_BUTTON);
use base 'Wx::Panel';

my $last_skein_dir;
my $last_config_dir;
my $last_input_file;
my $last_output_file;
our $last_config;

sub new {
    my $class = shift;
    my ($parent) = @_;
    my $self = $class->SUPER::new($parent, -1);
    
    my %panels = (
        printer => {
            title => 'Printer',
            options => [qw(print_center z_offset gcode_flavor use_relative_e_distances)],
            label_width => 230,
        },
        filament => {
            title => 'Filament',
            options => [qw(filament_diameter extrusion_multiplier temperature first_layer_temperature bed_temperature first_layer_bed_temperature)],
            label_width => 275,
        },
        speed => {
            title => 'Speed',
            options => [qw(perimeter_speed small_perimeter_speed infill_speed solid_infill_speed travel_speed bottom_layer_speed min_print_speed slowdown_below_layer_time)],
            label_width => 290,
        },
	bridge => {
	    title => 'Bridge settings',
	    options => [qw(nozzle_diameter bridge_speed bridge_fan_speed bridge_flow_ratio)],
            label_width => 275,
	},
        accuracy => {
            title => 'Accuracy',
            options => [qw(layer_height first_layer_height extrusion_width)],
            label_width => 290,
        },
        print => {
            title => 'Print settings',
            options => [qw(perimeters solid_layers fill_density fill_angle fill_pattern infill_every_layers solid_fill_pattern)],
            label_width => 125,
        },
	support => {
	    title => 'Support',
	    options => [qw(support_material support_material_tool)],
            label_width => 240,
	},
        retract => {
            title => 'Retraction',
            options => [qw(retract retract_length combine_lift retract_lift retract_restart_extra retract_before_travel combine_z)],
            label_width => 240,
        },
        cooling => {
            title => 'Cooling',
            options => [qw(cooling min_fan_speed max_fan_speed fan_below_layer_time disable_fan_first_layers fan_always_on)],
            label_width => 295,
        },
        skirt => {
            title => 'Skirt',
            options => [qw(skirts skirt_distance skirt_height)],
            label_width => 290,
        },
        brim => {
            title => 'Brim',
            options => [qw(brim_width)],
            label_width => 275,
        },
        transform => {
            title => 'Transform',
            options => [qw(scale rotate duplicate_mode duplicate bed_size duplicate_grid duplicate_distance)],
            label_width => 245,
        },
        gcode => {
            title => 'Custom G-code',
            options => [qw(output_filename_format start_gcode end_gcode layer_gcode gcode_comments post_process)],
        },
        notes => {
            title => 'Notes',
            options => [qw(notes)],
        },
    );
    $self->{panels} = \%panels;

    if (eval "use Growl::GNTP; 1") {
        # register growl notifications
        eval {
            $self->{growler} = Growl::GNTP->new(AppName => 'Slic3T', AppIcon => "$FindBin::Bin/var/Slic3T.png");
            $self->{growler}->register([{Name => 'SKEIN_DONE', DisplayName => 'Slicing Done'}]);
        };
    }
    
    my $tabpanel = Wx::Notebook->new($self, -1, Wx::wxDefaultPosition, Wx::wxDefaultSize, &Wx::wxNB_TOP);
    my $make_tab = sub {
        my @cols = @_;
        
        my $tab = Wx::Panel->new($tabpanel, -1);
        my $sizer = Wx::BoxSizer->new(wxHORIZONTAL);
        foreach my $col (@cols) {
            my $vertical_sizer = Wx::BoxSizer->new(wxVERTICAL);
            for my $optgroup (@$col) {
                my $optpanel = Slic3T::GUI::OptionsGroup->new($tab, %{$panels{$optgroup}});
                $vertical_sizer->Add($optpanel, 0, wxEXPAND | wxALL, 10);
            }
            $sizer->Add($vertical_sizer);
        }
        
        $tab->SetSizer($sizer);
        return $tab;
    };
    
    my @tabs = (
        $make_tab->([qw(accuracy speed)], [qw(print bridge)]),
        $make_tab->([qw(transform skirt)], [qw(support filament brim)]),
        $make_tab->([qw(printer cooling)], [qw(retract)]),
        $make_tab->([qw(gcode)]),
        $make_tab->([qw(notes)]),
    );
    
    $tabpanel->AddPage($tabs[0], "Print Settings 1");
    $tabpanel->AddPage($tabs[1], "Print Settings 2");
    $tabpanel->AddPage($tabs[2], "Printer and Cooling");
    $tabpanel->AddPage($tabs[3], "Custom G-code");
    $tabpanel->AddPage($tabs[4], "Notes");
        
    my $buttons_sizer;
    {
        $buttons_sizer = Wx::BoxSizer->new(wxHORIZONTAL);
        
        my $slice_button = Wx::Button->new($self, -1, "Slice...");
        $slice_button->SetDefault();
        $buttons_sizer->Add($slice_button, 0);
        EVT_BUTTON($self, $slice_button, sub { $self->do_slice });
        
        my $slice_button = Wx::Button->new($self, -1, "Slice and Save as...");
        $slice_button->SetDefault();
        $buttons_sizer->Add($slice_button, 0);
        EVT_BUTTON($self, $slice_button, sub { $self->do_slice(save_as => 1) });

        my $reslice_button = Wx::Button->new($self, -1, "Reslice...");
        $buttons_sizer->Add($reslice_button, 0, wxRIGHT, 30);
        EVT_BUTTON($self, $reslice_button, sub { $self->do_slice(reslice => 1) });
        
        my $save_button = Wx::Button->new($self, -1, "Save config...");
        $buttons_sizer->Add($save_button, 0);
        EVT_BUTTON($self, $save_button, sub { $self->save_config });
        
        my $load_button = Wx::Button->new($self, -1, "Load config...");
        $buttons_sizer->Add($load_button, 0);
        EVT_BUTTON($self, $load_button, sub { $self->load_config });
        
        my $text = Wx::StaticText->new($self, -1, "  Slic3T - v$Slic3T::VERSION", Wx::wxDefaultPosition, Wx::wxDefaultSize, wxALIGN_RIGHT);
        my $font = Wx::Font->new(16, wxDEFAULT, wxNORMAL, wxNORMAL);
        $text->SetFont($font);
        $buttons_sizer->Add($text, 1, wxEXPAND | wxALIGN_RIGHT);
    }
    
    my $sizer = Wx::BoxSizer->new(wxVERTICAL);
    $sizer->Add($buttons_sizer, 0, wxEXPAND | wxALL, 10);
    $sizer->Add($tabpanel);
    
    $sizer->SetSizeHints($self);
    $self->SetSizer($sizer);
    $self->Layout;
    
    $_->() for @Slic3T::GUI::OptionsGroup::reload_callbacks;
    
    return $self;
}

my $model_wildcard = "STL files (*.stl)|*.stl;*.STL|AMF files (*.amf)|*.amf;*.AMF;*.xml;*.XML";
my $ini_wildcard = "INI files *.ini|*.ini;*.INI";
my $gcode_wildcard = "G-code files *.gcode|*.gcode;*.GCODE;*.g;*.G";

sub do_slice {
    my $self = shift;
    my %params = @_;
    
    my $process_dialog;
    eval {
        # validate configuration
        Slic3T::Config->validate;

        # confirm slicing of more than one copies
        my $copies = $Slic3T::duplicate_grid->[X] * $Slic3T::duplicate_grid->[Y];
        $copies = $Slic3T::duplicate if $Slic3T::duplicate > 1;
        if ($copies > 1) {
            my $confirmation = Wx::MessageDialog->new($self, "Are you sure you want to slice $copies copies?",
                                                      'Confirm', wxICON_QUESTION | wxOK | wxCANCEL);
            return unless $confirmation->ShowModal == wxID_OK;
        }
        
        # select input file
        my $dir = $last_skein_dir || $last_config_dir || "";

        my $input_file;
        if (!$params{reslice}) {
            my $dialog = Wx::FileDialog->new($self, 'Choose a STL or AMF file to slice:', $dir, "", $model_wildcard, wxFD_OPEN);
            return unless $dialog->ShowModal == wxID_OK;
            $input_file = $dialog->GetPaths;
            $last_input_file = $input_file;
        } else {
            if (!defined $last_input_file) {
                Wx::MessageDialog->new($self, "No previously sliced file",
                                       'Confirm', wxICON_ERROR | wxOK)->ShowModal();
                return;
            }
            if (! -e $last_input_file) {
                Wx::MessageDialog->new($self, "Cannot find previously sliced file!",
                                       'Confirm', wxICON_ERROR | wxOK)->ShowModal();
                return;
            }
            $input_file = $last_input_file;
        }
        my $input_file_basename = basename($input_file);
        $last_skein_dir = dirname($input_file);
        
        my $skein = Slic3T::Skein->new(
            input_file  => $input_file,
            output_file => $main::opt{output},
            status_cb   => sub {
                my ($percent, $message) = @_;
                if (&Wx::wxVERSION_STRING =~ / 2\.(8\.|9\.[2-9])/) {
                    $process_dialog->Update($percent, "$message...");
                }
            },
        );

        # select output file
        if ($params{reslice}) {
            if (defined $last_output_file) {
                $skein->output_file($last_output_file);
            }
        } elsif ($params{save_as}) {
            my $output_file = $skein->expanded_output_filepath;
            $output_file =~ s/\.gcode$/.svg/i if $params{export_svg};
            my $dlg = Wx::FileDialog->new($self, 'Save ' . ($params{export_svg} ? 'SVG' : 'G-code') . ' file as:', dirname($output_file),
                basename($output_file), $gcode_wildcard, wxFD_SAVE);
            return if $dlg->ShowModal != wxID_OK;
            $skein->output_file($dlg->GetPath);
            $last_output_file = $dlg->GetPath;
        }
        
        # show processbar dialog
        $process_dialog = Wx::ProgressDialog->new('Slicing...', "Processing $input_file_basename...", 
            100, $self, 0);
        $process_dialog->Pulse;
        
        {
            my @warnings = ();
            local $SIG{__WARN__} = sub { push @warnings, $_[0] };
            if ($params{export_svg}) {
                $skein->export_svg;
            } else {
                $skein->go;
            }
            $self->catch_warning->($_) for @warnings;
        }
        $process_dialog->Destroy;
        undef $process_dialog;
        
        my $message = "$input_file_basename was successfully sliced";
        $message .= sprintf " in %d minutes and %.3f seconds",
            int($skein->processing_time/60),
            $skein->processing_time - int($skein->processing_time/60)*60
            if $skein->processing_time;
        $message .= ".";
        eval {
            $self->{growler}->notify(Event => 'SKEIN_DONE', Title => 'Slicing Done!', Message => $message)
                if ($self->{growler});
        };
        Wx::MessageDialog->new($self, $message, 'Done!', 
            wxOK | wxICON_INFORMATION)->ShowModal;
    };
    $self->catch_error(sub { $process_dialog->Destroy if $process_dialog });
}

sub save_config {
    my $self = shift;
    
    my $process_dialog;
    eval {
        # validate configuration
        Slic3T::Config->validate;
    };
    $self->catch_error(sub { $process_dialog->Destroy if $process_dialog }) and return;
    
    my $dir = $last_config ? dirname($last_config) : $last_config_dir || $last_skein_dir || "";
    my $filename = $last_config ? basename($last_config) : "config.ini";
    my $dlg = Wx::FileDialog->new($self, 'Save configuration as:', $dir, $filename, 
        $ini_wildcard, wxFD_SAVE);
    if ($dlg->ShowModal == wxID_OK) {
        my $file = $dlg->GetPath;
        $last_config_dir = dirname($file);
        $last_config = $file;
        Slic3T::Config->save($file);
    }
}

sub load_config {
    my $self = shift;
    
    my $dir = $last_config ? dirname($last_config) : $last_config_dir || $last_skein_dir || "";
    my $dlg = Wx::FileDialog->new($self, 'Select configuration to load:', $dir, "config.ini", 
        $ini_wildcard, wxFD_OPEN);
    if ($dlg->ShowModal == wxID_OK) {
        my ($file) = $dlg->GetPaths;
        $last_config_dir = dirname($file);
        $last_config = $file;
        eval {
            local $SIG{__WARN__} = $self->catch_warning;
            Slic3T::Config->load($file);
        };
        $self->catch_error();
        $_->() for @Slic3T::GUI::OptionsGroup::reload_callbacks;
    }
}

sub catch_error {
    my ($self, $cb) = @_;
    if (my $err = $@) {
        $cb->() if $cb;
        Wx::MessageDialog->new($self, $err, 'Error', wxOK | wxICON_ERROR)->ShowModal;
        return 1;
    }
    return 0;
}

sub catch_warning {
    my ($self) = @_;
    return sub {
        my $message = shift;
        Wx::MessageDialog->new($self, $message, 'Warning', wxOK | wxICON_WARNING)->ShowModal;
    };
};

1;
