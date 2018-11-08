module Zeptobot

using HTTP, JSON, GitHub, Dates, Sockets, Logging

USERNAME  = Ref{String}()
TOKEN     = Ref{String}()
LOGDIR    = Ref{String}()
REGISTRATION_OK_AGE = Day(3)

function __init__()
    if haskey(ENV, "GITHUB_USERNAME")
        USERNAME[] = ENV["GITHUB_USERNAME"]
    else
        print("Please enter a GitHub username: ")
        USERNAME[] = readline(stdin)
    end

    if haskey(ENV, "GITHUB_TOKEN")
        TOKEN[] = ENV["GITHUB_TOKEN"]
    else
        print("Please enter a GitHub token: ")
        TOKEN[] = readline(stdin)
    end

    if haskey(ENV, "ZEPTO_LOGDIR")
        LOGDIR[] = ENV["ZEPTO_LOGDIR"]
    else
        print("Please enter a path to the log directory: ")
        LOGDIR[] = readline(stdin)
    end
end

function parsepageinfo(s::AbstractString)
    ss = split(s, ',')
    rels_n_pages = map(t -> (strip(match(r"(?<=rel=).*", t).match, '\"'),
                             strip(match(r"(?<=<)(.*)(?=>)", t).match, '\"')),
                       ss)
    return Dict(rels_n_pages)
end

function _requestURL(s::AbstractString, type = "GET"; kw...)
    d = Dict(kw)
    r = HTTP.request(type,
                     s,
                     Dict("User-Agent" => USERNAME[],
                          "Authorization" => "token $(TOKEN[])",
                          "Accept" => "application/vnd.github.v3+json"),
                     # FixMe! We should probably strip all parameters from
                     # s as well.
                     query = isempty(d) ? nothing : d,
                     retry = true,
                     retries = 10,
                     status_exception = false)

    if r.status >= 300
        return r, false
    end

    return r, true
end

function getURLallpages(s::AbstractString; kw...)
    if haskey(kw, :page)
        # @error "Don't pass page argument since this function tranverses all pages"
        error("Don't pass page argument since this function tranverses all pages")
    end

    entries = []

    r, noerr = _requestURL(s, "GET", kw...)

    # Traverse the pages
    while true
        # For now just error if request didn't succeed
        if noerr
            # If success then parse the body
            append!(entries, JSON.parse(String(r.body)))

            # Parse the page info in the header
            d = Dict(r.headers)
            if haskey(d, "Link")
                pd = parsepageinfo(d["Link"])
            else
                @debug "Single page document"
                break
            end

            # If the header doesn't contain info about the next page then we are done
            if !haskey(pd, "next")
                @debug "No more pages to read"
                break
            else
                # else read the next page
                @debug "Reading page $(match(r"(?<=page=)[0-9]", pd["next"]).match)"
                r, noerr = _requestURL(pd["next"], "GET")
            end
        else
            @error "Request returned an error"
            break
        end
    end

    return entries
end

getPRs(;repo = "JuliaLang/METADATA.jl") = pull_requests(repo, params = Dict("state" => "open"))

getStatuses(pr::PullRequest) = getURLallpages(pr._links["statuses"]["href"])

getComments(pr::PullRequest) = getURLallpages(pr._links["comments"]["href"])

function checkComments(pr::PullRequest)
    comments = getComments(pr)
    # It's okay to merge if there are no comments or if the latest comment
    # is made by Attobot since it indicates that the PR has been updated
    return isempty(comments) || last(comments)["user"]["login"] == "attobot"
end

getLabels(pr::PullRequest) = getURLallpages(pr._links["issue"]["href"]*"/labels")

function checkLabels(pr)
    labels = getLabels(pr)
    # For now we abort on any label
    return isempty(labels)
end

function mergeable(pr::PullRequest)
    # Only do something with PRs not made by Attobot
    if pr.user.login != "attobot"
        @info "Skipping: PR not by Attobot"
        return false
    end

    # Check for comments
    @info "Checking for comments"
    if !checkComments(pr)
        @info "Skipping: PR contains comments"
        return false
    end

    # Check test status
    @info "Checking test status"
    statuses = map(t -> t["context"], filter(t -> t["state"] == "success", getStatuses(pr)))
    if !(("JuliaCIBot" ∈ statuses) &&
         ("continuous-integration/travis-ci/pr" ∈ statuses))
        @info "Skipping: Tests failed or still in progess"
        return false
    end

    # Check labels
    @info "Checking issue labels"
    if !checkLabels(pr)
        @info "Skipping: PR has labels attached"
        return false
    end

    # Handle releases (i.e. not new registrations)
    if occursin(r"Tag .*\.jl v[\d.\d.\d]", pr.title)

        @info "PR tries tag new release"

        return true

    elseif occursin(r"Register new package .*\.jl v[\d.\d.\d]", pr.title)

        @info "PR tries to register new package"

        if (now(UTC) - pr.created_at) >= REGISTRATION_OK_AGE
            return true
        else
            @info "Skipping: PR is younger than $REGISTRATION_OK_AGE"
            return false
        end
    else
        throw(ErrorException("this should never happen!"))
    end
end

function merge(pr::PullRequest;
    title = "$(pr.title) [$(match(r"(?<=\()(.*)(?=\))",pr.body).match)] (#$(pr.number))",
    comment = "Merged automatically by Zeptobot")
    
    r = HTTP.request(
        "PUT",
        "http://api.github.com/repos/$(pr.base.repo.full_name)/pulls/$(pr.number)/merge",
        Dict("User-Agent" => USERNAME[],
             "Authorization" => "token $(TOKEN[])",
             "Accept" => "application/vnd.github.v3+json"),
        JSON.json(
            Dict(
                "commit_title" => title,
                "commit_message" => comment,
                "merge_method" => "squash")
        ),
        retry = true,
        retries = 10,
        status_exception = false
    )

    return r
end

# FixMe! Not implemented yet
closeable(pr) = false

function process(;repo = "JuliaLang/METADATA.jl", prs::Vector{PullRequest} = pull_requests(repo, params = Dict("state" => "open"))[1], dryrun = false)

    if dryrun
        @warn "Running in dry-run mode. No actions taken."
    end

    merge_count         = 0
    merge_count_success = 0
    close_count         = 0
    close_count_success = 0

    @info "Traverse the PRs to determine actions"
    for pr in prs

        title = pr.title

        @info "Processing \"$title\""

        if mergeable(pr)

            @info "PR can be merged"
            merge_count += 1
            if !dryrun
                r = merge(pr)
                if r.status >= 300
                    @error "Merging failed with: $(String(r.body))"
                else
                    @info "Merge successful!"
                    merge_count_success += 1
                end
            end
            @info ""
            sleep(10)

        elseif closeable(pr)

            # FixME. Closing not implemented yet!
            @info "PR can be closed"
            close_count += 1
            if !dryrun
                r = close(pr)
                if r.status >= 300
                    @error "Closing PR failed with: $(String(r.body))"
                else
                    @info "PR closed successfully!"
                    close_count_success += 1
                end
            end

        else

            # do nothing
            @info ""

        end
    end

    @info "PR processing complete"
    @info "$merge_count_success out of $merge_count PRs merged successfully"
    @info "$close_count_success out of $close_count PRs closed successfully"

    return nothing
end

function restartPending(;repo = "JuliaLang/METADATA.jl", prs::Vector{PullRequest} = pull_requests(repo, params = Dict("state" => "open"))[1])

    for pr in prs
        # Check test status
        @info "Checking test status"
        statuses = map(t -> t["context"], filter(t -> t["state"] == "success", getStatuses(pr)))
        if !(("JuliaCIBot" ∈ statuses) &&
             ("continuous-integration/travis-ci/pr" ∈ statuses))
            @info "Skipping: Tests failed or still in progess"
            return false
        end
    end
end

# A small server to listen for METADATA events and run process if necessary
function serveMETADATA(;repo = "JuliaLang/METADATA.jl", port = 6384, auth = GitHub.authenticate(Zeptobot.TOKEN[]), secret = "")

    # Initialize "global" counter for the logs
    logcounter = 0

    # Setup EventListener
    e = GitHub.EventListener(auth = auth, secret = secret) do event

        # Create daily logging directory if needed
        todaydir = joinpath(LOGDIR[], replace(string(today()), "-" => ""))
        if !isdir(todaydir)
            mkdir(todaydir)
            logcounter = 1
        elseif isempty(todaydir)
            logcounter = 1
        else
            # Find the latest job id
            logcounter = parse(Int, match(r"[0-9]{4}", last(sort(readdir(todaydir)))).match) + 1
        end
        
        # Setup logfile environment
        prefix = joinpath(todaydir, "job$(lpad(logcounter, 4, '0'))")
        open(prefix*"stderr.log", "w") do f
            with_logger(SimpleLogger(f)) do

            @info "Received an event from GitHub. Processing!"
            if event.kind != "status"
                @error "event is not a status update"
                return HTTP.Response(500)
            else
                name = event.payload["name"]
                if name != repo
                    @error "Received an event from the wrong repo"
                    return HTTP.Response(500)
                end

                if event.payload["state"] == "success"
                    @info "Event status: success. Trying to merge PRs..."
                    process(repo = repo)
                    return HTTP.Response(200)
                else
                    @info "Status: pending"
                    return HTTP.Response(200)
                end
            end
        end
        end
    end

    if !isdir(LOGDIR[])
        @info "Creating log directory"
        mkdir(LOGDIR[])
    end

    GitHub.run(e, getipaddr(), port)
    return nothing
end

end
