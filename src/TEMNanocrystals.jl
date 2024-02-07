"""
# TEMNanocrystals

This is an adaptation of the watershed algorithm described [here](https://juliaimages.org/latest/pkgs/segmentation/#Watershed) 
to get statistics on nanocrystals of perovskite imaged through Transmission 
Electron Microscopy (TEM). We have used it in papers reporting the synthesis of
these objects [[1]](https://doi.org/10.1039/D2CC01028C).
"""
module TEMNanocrystals

# The GUI is generated through the Gtk library, and the plots through Makie.jl

using Gtk4, Gtk4.GLib, GtkObservables, Gtk4Makie
using GLMakie
using Colors
using Images, ImageSegmentation
using Distributions
using Printf
using Random

# The following references will hold the application, the screen on which the
# figures are plotted, and a layout in which the other GUI elements are stored.
const rapp = Ref{GtkApplication}()
const rscreen = Ref{GLMakie.Screen}()
const rlayout = Ref{GtkBoxLeaf}()
const rfig = Ref{Figure}()

"""
    julia_main()

Main function. Runs the application.
"""
function julia_main()::Cint
    app = GtkApplication("julia.gtk4.temnanocrystals")

    rapp[] = app

    Gtk4.signal_connect(activate, app, :activate)

    # Runs the application in background if ran in the REPL.
    if isinteractive()
        loop() = Gtk4.run(app)
        schedule(Task(loop))
    else
        Gtk4.run(app)
    end

    return 0
end

# Gtk4 stuff.
function on_state_changed(a, v)
    Gtk4.GLib.set_state(a, v)
    b = v[Bool]
end

"""
Initialize the application. Create the layout.
"""
function activate(app)
    add_stateful_action(GActionMap(app), "toggle", false, on_state_changed)

    app = rapp[]
    screen = Gtk4Makie.GTKScreen(resolution=(800, 800), title="TEM Nanocrystals Images Analyzer", app=app)
    rscreen[] = screen
    g = grid(screen)

    g.column_spacing = 15
    g.row_spacing = 15

    fig = Figure(size=(600, 600))
    display(screen, fig)
    rfig[] = fig

    layout = GtkBox(:h)
    layout.spacing = 10
    layout.margin_bottom = 10
    layout.margin_start = 10
    layout.margin_top = 10
    layout.margin_end = 10
    g[1,2] = layout
    rlayout[] = layout

    win = window(screen)
    hb = win.titlebar
    about_Button = GtkButton(icon_name="help-about")
    pushfirst!(hb, about_Button)
    signal_connect(about_Button, "clicked") do adjustment
        about()
    end

    display_first_panel()
end

"""
Show the "About" dialog.
"""
function about()
    dialog = GtkAboutDialog()
    dialog.program_name = "TEM Nanocrystals Images Watershed" 
    dialog.comments = "Get statistics on the sizes of nanocrystals from TEM images."
    dialog.copyright = "Copyright (c) 2024 Hugo Levy-Falk <klafyvel@klafyvel.me> and contributors"
    dialog.license_type = Gtk4.License_MIT_X11
    dialog.website =  "https://github.com/klafyvel/TEMNanocrystals"
    show(dialog)
end

# The appplication works in seven panels. We define a function tasked with 
# displaying each panel.
function display_first_panel end
function display_second_panel end
function display_third_panel end
function display_fourth_panel end
function display_fifth_panel end
function display_sixth_panel end
function display_seventh_panel end

# We will do that often
"""
    clean_and_new_figure(unit, title)

Clear the global figure and widgets layout, and create a new axis suited for
displaying an image. If you need another kind of axis, just `empty!` the figure
afterwards.

Returns the screen, widget layout, figure, and axis.
"""
function clean_and_new_figure(unit, title)
    screen = rscreen[]
    hbox = rlayout[]
    empty!(hbox)
    fig = rfig[]
    empty!(fig)
    ax = Makie.Axis(
        fig[1, 1], xlabel="x ($unit)", ylabel="y ($unit)",
        yreversed=true, aspect=DataAspect(),
        xaxisposition=:top, alignmode=Inside(),
        xlabelsize=12, ylabelsize=12,
        xticklabelsize=10, yticklabelsize=10,
        title=title
    )
    return screen, hbox, fig, ax
end

# First panel: image selection.
const displayed_image = Observable{Matrix}(zeros(Gray, 128, 128))
const filename = Observable{String}()

"""
First panel: Image selection and loading. You can load the image by clicking
on the `Browse...` button. Once done, you can click on `Next`.
"""
function display_first_panel()
    screen, hbox, fig, ax = clean_and_new_figure("pixels", "Selected image")
    ax.subtitle = "Use Ctrl + click to reset the display."

    image!(ax, @lift(transpose($displayed_image)))

    # GUI elements of the first panel.
    filename_Label = GtkLabel("File:")
    filename_Entry = textbox("", observable=filename)
    browse_Button = button("Browse...")
    spacer = GtkBox(:h)
    spacer.hexpand = true
    next_Button = button("Next")
    push!(hbox, filename_Label)
    push!(hbox, filename_Entry)
    push!(hbox, browse_Button)
    push!(hbox, spacer)
    push!(hbox, next_Button)

    # We use GtkObservables.jl to dynamically update values, here the loaded
    # image.
    on(observable(browse_Button)) do _
        win = window(screen)
        open_dialog("Choose image.", win, (GtkFileFilter("*.tif, *.jpg, *.jpeg", name="All supported formats"), "*.tif", "*.jpg", "*.jpeg")) do f
            if isfile(f)
                filename[] = f
                displayed_image[] = Gray.(load(f))
                autolimits!(ax)
            end
        end
    end

    # Once the user is happy with their image they can go to the next panel.
    on(observable(next_Button)) do _
        display_second_panel()
    end
end

# Second panel: Identification of the scalebar
const image_scale = Observable{Matrix}()
const pixel_size = Observable{Float64}(1)
const size_image = @lift size($displayed_image)
const x_image = @lift 0 .. ($size_image[2] * $pixel_size)
const y_image = @lift 0 .. ($size_image[1] * $pixel_size)
const scalebar_size = Observable{Float64}(100.0)

"""
The program needs to know the scale, so it can translate the sizes from pixels
to nanometers. Fill-in the size of the scale bar, then select it in the image view.

The program will look for the left-most and right-most white pixels in you selection.
This means you need to ensure that no unwanted white pixel remains in your selection.

You can visualize the result when you click on `Next`.
"""
function display_second_panel()
    screen, hbox, fig, ax = clean_and_new_figure("pixels", "Please, select the scale bar")
    ax.subtitle = "Use Ctrl + click to reset the display."
    image!(ax, @lift(transpose($displayed_image)))

    scale_Label = GtkLabel("Scale (nm):")
    scale_value_Adjustment = GtkAdjustment(scalebar_size[], 0, 10_000, 1, 50, 0)
    scale_value_SpinButton = GtkSpinButton(scale_value_Adjustment, 1, 0)
    signal_connect(scale_value_Adjustment, "value-changed") do adjustment
        scalebar_size[] = get_gtk_property(adjustment, :value, Float64)
    end
    prev_Button = button("Previous")
    done_Button = button("Done")
    spacer = GtkBox(:h)
    spacer.hexpand = true
    reset_Button = button("Previous")
    next_Button = button("Next")
    push!(hbox, scale_Label)
    push!(hbox, scale_value_SpinButton)
    push!(hbox, spacer)
    push!(hbox, prev_Button)
    push!(hbox, done_Button)

    on(observable(reset_Button)) do _
        display_second_panel()
    end
    on(observable(prev_Button)) do _
        display_first_panel()
    end
    on(observable(next_Button)) do _
        display_third_panel()
    end
    on(observable(done_Button)) do _
        empty!(hbox)
        push!(hbox, spacer)
        push!(hbox, reset_Button)
        push!(hbox, next_Button)
        zoom_rect = ax.finallimits[]
        startx = floor(Int, zoom_rect.origin[2])
        stopx = ceil(Int, zoom_rect.origin[2] + zoom_rect.widths[2])
        starty = floor(Int, zoom_rect.origin[1])
        stopy = ceil(Int, zoom_rect.origin[1] + zoom_rect.widths[1])
        maxi = maximum(displayed_image[][startx:stopx, starty:stopy])
        image_scale[] = Gray.(displayed_image[][startx:stopx, starty:stopy] .== maxi)
        pixel_size[] = let
            scalebar = findall(image_scale[] .== 1)
            scalebar_size[] / (maximum(x -> x[2], scalebar) - minimum(x -> x[2], scalebar))
        end
        empty!(fig)
        ax = Makie.Axis(
            fig[1, 1], xlabel="x (pixels)", ylabel="y (pixels)",
            yreversed=true, aspect=DataAspect(),
            xaxisposition=:top, alignmode=Inside(),
            xlabelsize=12, ylabelsize=12,
            xticklabelsize=10, yticklabelsize=10,
            title="Scalebar", subtitle="$scalebar_size nm, pixel size : $(pixel_size[]) nm"
        )
        image!(ax, transpose(image_scale[]))
    end
end

# Third panel: Thresholding
# We want to define a threshold to define what is a nanocrystal and what is in
# the background.

const image_bw = Observable{Matrix}()
const threshold = Observable{Float64}(0.5)
const threshold_correction = Observable{Bool}(false)

function compute_thresholded()
    image_bw[] = threshold[] .< Gray.(displayed_image[])
    if threshold_correction[]
        image_bw[] = let
            flood_start = findfirst(image_bw[])
            one_np = map(x -> (x, 2), findall(!, image_bw[]))
            seeded_region = seeded_region_growing(image_bw[], [(flood_start, 1), one_np...])
            (labels_map(seeded_region) .== 1)
        end
    end

end

"""
The program needs to know which pixels belong to the background and which pixels
don't. This is done by thresholding the image: we set a threshold gray level. If
a pixel is darker than the threshold it is in a nanocrystal, otherwise it is in
the background. 

This procedure can leave holes in the nanocrystal. You can try to patch them by
activating the `Seed Growing` option. Be aware that this operation is slow and
may lead to accidentally merging nanocrystals.
"""
function display_third_panel()
    screen, hbox, fig, ax = clean_and_new_figure("nm", "Thresholded image")

    threshold_level_Label = GtkLabel("Threshold level:")
    threshold_level_Adjustment = GtkAdjustment(threshold[], 0, 1, 0.01, 0.1, 0)
    threshold_level_SpinButton = GtkSpinButton(threshold_level_Adjustment, 1, 2)
    threshold_correction_Label = GtkLabel("Use Seed Growing")
    threshold_correction_Switch = GtkSwitch(threshold_correction[])
    spacer = GtkBox(:h)
    spacer.hexpand = true
    prev_Button = button("Previous")
    next_Button = button("Next")
    push!(hbox, threshold_level_Label)
    push!(hbox, threshold_level_SpinButton)
    push!(hbox, threshold_correction_Label)
    push!(hbox, threshold_correction_Switch)
    push!(hbox, spacer)
    push!(hbox, prev_Button)
    push!(hbox, next_Button)

    signal_connect(threshold_level_Adjustment, "value-changed") do adjustment
        threshold[] = get_gtk_property(adjustment, :value, Float64)
        compute_thresholded()
        ax.subtitle[] = "Threshold = $(threshold[]), Filling enabled = $(threshold_correction[])"
    end
    signal_connect(threshold_correction_Switch, "state-set") do switch, _...
        threshold_correction[] = get_gtk_property(switch, :active, Bool)
        compute_thresholded()
        ax.subtitle[] = "Threshold = $(threshold[]), Filling enabled = $(threshold_correction[])"
    end

    compute_thresholded()
    ax.subtitle[] = "Threshold = $(threshold[]), Filling enabled = $(threshold_correction[])"
    image!(ax, x_image[], y_image[], @lift(transpose($image_bw)))

    on(observable(prev_Button)) do _
        display_second_panel()
    end
    on(observable(next_Button)) do _
        display_fourth_panel()
    end
end

# Fourth panel: compute distance transform
# For each pixel, mark the distance to the background.
# This is the distance transform.

const image_distance_transform = Observable{Matrix}()

"""
The fourth panel does not require any action on your part. It simply consists in
computing the distance transform of the image. That is, for each pixel in the image,
compute its distance to the background.
"""
function display_fourth_panel()
    screen, hbox, fig, ax = clean_and_new_figure("nm", "Distance transform")

    image_distance_transform[] = 1 .- distance_transform(feature_transform(image_bw[]))
    a = (image_distance_transform[] ./ abs(quantile(vec(image_distance_transform[]), 0.005))) .+ 1
    dist_img = clamp.(a, 0.0, 1.0) .|> Gray
    image!(ax, x_image[], y_image[], transpose(dist_img))

    spacer = GtkBox(:h)
    spacer.hexpand = true
    prev_Button = button("Previous")
    next_Button = button("Next")
    push!(hbox, spacer)
    push!(hbox, prev_Button)
    push!(hbox, next_Button)

    on(observable(prev_Button)) do _
        display_third_panel()
    end
    on(observable(next_Button)) do _
        display_fifth_panel()
    end
end

# Fifth panel : Markers

const markers = Observable{Matrix}()
const quantile_markers = Observable{Float64}(0.9)

function display_distance_distribution(fig)
    maxi_dist = @lift(pixel_size[] * quantile(vec(image_distance_transform[]), 1 - $quantile_markers))
    empty!(fig)
    ax = Makie.Axis(
        fig[1, 1], xlabel="Distance (nm)", ylabel="Count",
        title="Distribution of distances to background"
    )
    hist!(ax, vec(image_distance_transform[] .* pixel_size[]), label="Distance distribution", bins=50)
    vlines!(ax, maxi_dist, label="Marker threshold", color=:red)
    axislegend(ax)
end

function display_markers(fig)
    maxi_dist = @lift(quantile(vec(image_distance_transform[]), 1 - $quantile_markers))
    markers_image = @lift((image_distance_transform[] .< $maxi_dist) .|> Gray)
    empty!(fig)
    ax = Makie.Axis(
        fig[1, 1], xlabel="x (nm)", ylabel="y (nm)",
        yreversed=true, aspect=DataAspect(),
        xaxisposition=:top, alignmode=Inside(),
        xlabelsize=12, ylabelsize=12,
        xticklabelsize=10, yticklabelsize=10,
        title="Markers"
    )
    image!(ax, x_image[], y_image[], @lift(transpose($markers_image)))
end

function compute_markers()
        maxi_dist = (quantile(vec(image_distance_transform[]), 1 - quantile_markers[]))
        # Label each component. That way, the markers that are neighbors are considered
        # one and unique nanoparticle.
        markers[] = label_components(image_distance_transform[] .< maxi_dist)
end

"""
The program uses the watershed algorithm to distinguish between the nanocrystals.
The algorithm will be explained later, but for now we need to find for each
nanoparticle some pixels we are sure belong to the nanoparticle. We will call them
markers.

We will choose the pixels most distant to nanocrystal borders. You need to choose 
the corresponding quantile of pixels to set as starting points. As an example, 
if you choose 0.90 then, to be considered as a marker, a pixel must be farther 
away from the background than 90% of all the other pixels. To help, you can draw
the pixel distance distribution.
"""
function display_fifth_panel()
    screen, hbox, fig, ax = clean_and_new_figure("nm", "Markers")

    show_distance_distribution_Button = button("Distance distribution")
    show_markers_Button = button("Markers")
    quantile_Label = GtkLabel("Quantile:")
    quantile_Adjustment = GtkAdjustment(quantile_markers[], 0, 1, 0.01, 0.1, 0)
    quantile_SpinButton = GtkSpinButton(quantile_Adjustment, 1, 2)
    id = signal_connect(quantile_Adjustment, "value-changed") do adjustment
        quantile_markers[] = get_gtk_property(adjustment, :value, Float64)
        compute_markers()
    end
    compute_markers()
    spacer = GtkBox(:h)
    spacer.hexpand = true
    prev_Button = button("Previous")
    next_Button = button("Next")
    push!(hbox, show_distance_distribution_Button)
    push!(hbox, show_markers_Button)
    push!(hbox, quantile_Label)
    push!(hbox, quantile_SpinButton)
    push!(hbox, spacer)
    push!(hbox, prev_Button)
    push!(hbox, next_Button)

    on(observable(show_distance_distribution_Button)) do val
        display_distance_distribution(fig)
    end
    on(observable(show_markers_Button)) do val
        display_markers(fig)
    end
    on(observable(prev_Button)) do _
        signal_handler_disconnect(quantile_Adjustment, id)
        display_fourth_panel()
    end
    on(observable(next_Button)) do _
        signal_handler_disconnect(quantile_Adjustment, id)
        display_sixth_panel()
    end

    display_distance_distribution(fig)
end

# Sixth panel : Watershed to find the nanoparticles area

const border_width = Observable{Float64}(10)
const labeled_map = Observable{Matrix}()
const segments = Observable{SegmentedImage}()

function get_random_color(seed)
    Random.seed!(seed)
    rand(RGB{N0f8})
end

function compute_labeled_map()
    labeled_map_raw = labels_map(segments[]) .* (1 .- image_bw[])
    res = labeled_map_raw
    for label ∈ segment_labels(segments[])
        all_indices = findall(labeled_map_raw .== label)
        exclude = !all(
            x -> ((border_width[] + 1) < x[1] < (size_image[][1] - border_width[]))
            &&
                ((border_width[] + 1) < x[2] < (size_image[][2] - border_width[])),
            all_indices
        )
        if exclude
            res[all_indices] .= 0
        end
    end
    res
end

"""
The algorithm uses the "watershed" technique to find which nanoparticle each pixel 
belongs to. Basically you can imagine the distance transform to describe a set 
of valleys and mountains. Each marker (at the bottom of a valley, i.e. the farthest
away from the background as possible) sets the position of a water source. Each 
water source starts filling its valley, creating lakes. When two lakes meet, we
know we've found the separation between two nanoparticles. Note however that this
does not take into account the space between the nanoparticles and the background.
That is why in a second step we use the thresholded image we created at the 
begining to keep only the parts of the lakes that are in a nanoparticle.
"""
function display_sixth_panel()
    screen, hbox, fig, ax = clean_and_new_figure("nm", "Labelled map")

    segments[] = watershed(image_distance_transform[], markers[])
    labeled_map[] = compute_labeled_map()

    border_width_Label = GtkLabel("Border width:")
    border_width_Adjustment = GtkAdjustment(border_width[], 0, 100, 1, 10, 0)
    border_width_SpinButton = GtkSpinButton(border_width_Adjustment, 1, 2)
    spacer = GtkBox(:h)
    spacer.hexpand = true
    prev_Button = button("Previous")
    next_Button = button("Next")
    push!(hbox, border_width_Label)
    push!(hbox, border_width_SpinButton)
    push!(hbox, spacer)
    push!(hbox, prev_Button)
    push!(hbox, next_Button)

    signal_connect(border_width_Adjustment, "value-changed") do adjustment
        border_width[] = get_gtk_property(adjustment, :value, Float64)
        labeled_map[] = compute_labeled_map()
    end
    nice_img = @lift(transpose(map(i -> if i == 0
        RGB{N0f8}(0, 0, 0)
    else
        get_random_color(i)
    end, $labeled_map)))
    image!(ax, x_image[], y_image[], nice_img)

    on(observable(prev_Button)) do _
        display_fifth_panel()
    end
    on(observable(next_Button)) do _
        display_seventh_panel()
    end
end

# Seventh panel: Average size determination

const sizes = Observable{Vector}()
const fitted_distribution = Observable{Normal}()
const min_size_distribution = Observable{Float64}(0.0)
const max_size_distribution = Observable{Float64}(20.0)

function calculate_distribution()
    min_size = min_size_distribution[]
    max_size = max_size_distribution[]

    areas = [
        count(labeled_map[] .== label)
        for label ∈ segment_labels(segments[])
    ]

    sizes_raw = sqrt.(areas) .* pixel_size[]
    filtered_sizes = min_size .< sizes_raw .< max_size
    sizes[] = sizes_raw[filtered_sizes]
    fitted_distribution[] = fit(Normal, sizes[])
end

"""
We can then determine the average size of a nanoparticle. We do that by counting the 
number of pixel in each nanoparticle, and then taking the square root of this area.

For square nanoparticles, this yields the average side length. For rectangular
nanoparticles, this yields the geometric average of the two side lengths.

If you look at the "Labelled nanoparticles" image, you'll see that there are some
groups of nanoparticles that are detected as a unique nanoparticle. This will show in
the distribution as huge nanoparticles. Similarly, some noise pixels alone in the 
background can be detected as very small nanoparticles. To avoid that, you are 
allowed to threshold the size distribution around the expected size.
"""
function display_seventh_panel()
    screen, hbox, fig, ax = clean_and_new_figure("nm", "Nanoparticles size distribution")
    empty!(fig)
    calculate_distribution()
    params = map(fitted_distribution, sizes) do fitted,sizes
        @sprintf("µ=%.3g nm, σ=%.3g nm, n=%d particles", fitted.μ, fitted.σ, length(sizes))
    end
    ax = Makie.Axis(
        fig[1, 1],
        xlabel="Size (nm)",
        ylabel="Density (arb. u.)",
        title="Nanoparticles size distribution",
        subtitle=params,
        xtickformat=xs -> [@sprintf "%.1f" x for x ∈ xs],
        yticklabelsvisible=false,
        titlesize=24
    )

    min_size_Label = GtkLabel("Min. size:")
    min_size_Adjustment = GtkAdjustment(min_size_distribution[], 0, 100, 1, 10, 0)
    min_size_SpinButton = GtkSpinButton(min_size_Adjustment, 1, 2)
    max_size_Label = GtkLabel("Min. size:")
    max_size_Adjustment = GtkAdjustment(max_size_distribution[], 0, 100, 1, 10, 0)
    max_size_SpinButton = GtkSpinButton(max_size_Adjustment, 1, 2)
    spacer = GtkBox(:h)
    spacer.hexpand = true
    prev_Button = button("Previous")
    next_Button = button("Back to begining")
    push!(hbox, min_size_Label)
    push!(hbox, min_size_SpinButton)
    push!(hbox, max_size_Label)
    push!(hbox, max_size_SpinButton)
    push!(hbox, spacer)
    push!(hbox, prev_Button)
    push!(hbox, next_Button)

    signal_connect(min_size_Adjustment, "value-changed") do adjustment
        min_size_distribution[] = get_gtk_property(adjustment, :value, Float64)
        calculate_distribution()
    end
    signal_connect(max_size_Adjustment, "value-changed") do adjustment
        max_size_distribution[] = get_gtk_property(adjustment, :value, Float64)
        calculate_distribution()
    end

    hist!(ax, sizes, label="Data", bins=100, normalization=:pdf)
    lines!(ax, fitted_distribution, color=:red, linewidth=5, label="Fit")
    axislegend(ax)

    on(observable(prev_Button)) do _
        display_sixth_panel()
    end
    on(observable(next_Button)) do _
        display_first_panel()
    end
end

end
