Code.require_file("utils/json.ex", __DIR__)
Code.require_file("utils/banner.ex", __DIR__)

defmodule VuaDauMo do
  @moduledoc false

  @my_project "Vua Dau Mo Miniapp"
  @base_url "https://vdm.builderminiapp.online"
  @ref_code "ref_6004380466"
  @root __DIR__

  @reset "\e[0m"
  @bold "\e[1m"
  @red "\e[91m"
  @green "\e[92m"
  @yellow "\e[93m"

  @ad_wait 15
  @video_gap 900
  @campaign_wait 10
  @spin_wait 3
  @max_machine 30
  @min_claim 1

  @machine_rates [
    0,
    10_000,
    11_444,
    13_097,
    14_988,
    17_152,
    19_629,
    22_463,
    25_707,
    29_419,
    33_667,
    38_528,
    44_092,
    50_459,
    57_745,
    66_083,
    75_626,
    86_546,
    99_043,
    113_345,
    129_712,
    148_443,
    169_878,
    194_409,
    222_481,
    254_608,
    291_373,
    333_448,
    381_598,
    436_701,
    500_000
  ]

  @exchange_tiers [{2_000_000, 19_000}, {1_000_000, 9_000}, {500_000, 4_250}, {100_000, 800}]

  def ref_code, do: @ref_code

  def run do
    :logger.set_primary_config(:level, :error)
    install_signal_handler()

    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    Banner.set_title(@my_project)
    Banner.show_banner(@my_project)

    accounts = load_lines("data.txt")

    cond do
      accounts == [] ->
        red("File data.txt is empty, please add your initData entries")
        System.halt(1)

      true ->
        proxies = load_lines("proxy.txt")
        settings = load_settings()

        loop(accounts, proxies, settings, 1)
    end
  end

  defp loop(accounts, proxies, settings, cycle) do
    yellow("Starting automation cycle number #{cycle}")

    Enum.with_index(accounts)
    |> Enum.each(fn {account, index} ->
      if index > 0, do: IO.puts("")

      proxy = proxy_for(proxies, index)

      case proxy do
        nil -> :ok
        line -> yellow("Using proxy #{mask_proxy(line)}")
      end

      process_account(account, index, proxy)
    end)

    yellow("All accounts processed for cycle number #{cycle}")

    wait = sleep_seconds(settings)
    countdown(wait, "Next cycle starts in")
    Banner.show_banner(@my_project)
    loop(accounts, proxies, settings, cycle + 1)
  end

  defp process_account(account, index, proxy) do
    label = "account #{index + 1}"

    case login(account, proxy) do
      {:ok, state} ->
        user = state.user

        if get(user, "is_banned", false) do
          red("#{String.capitalize(label)} is banned and was skipped by the bot")
        else
          green(
            "Welcome back #{clean_text(get(user, "username", "Unknown"), "user")} with #{oil(get(user, "oil_balance", 0))} oil and #{money(get(user, "vnd_balance", 0))} VND"
          )

          state
          |> run_mining(proxy)
          |> run_video(proxy)
          |> run_campaigns(proxy)
          |> run_tickets(proxy)
          |> run_exchange(proxy)
        end

        :ok

      {:blocked, body} ->
        missing = get(body, "missing", [])

        yellow(
          "#{plural(length(missing), "mandatory channel")} still wait for a manual join on #{label}"
        )

        Enum.each(missing, fn entry ->
          yellow(
            "Channel #{clean_text(get(entry, "name", "channel"), "channel")} was not joined yet"
          )
        end)

      {:error, reason} ->
        red("Failed to fetch account state for #{label} with #{clean_text(reason, "error")}")
    end
  end

  defp run_mining(state, proxy) do
    user = state.user

    if get(user, "is_mining", false) do
      claimable = claimable_oil(user)

      if claimable >= @min_claim do
        case call("/api/claim", %{"initData" => state.account}, proxy) do
          {:ok, body} ->
            earned = get(body, "earned", 0)

            if is_number(earned) and earned >= @min_claim do
              green("Mining session was harvested for #{oil(earned)} oil and the machine stopped")
              %{state | user: get(body, "user", user)}
            else
              yellow("Oil storage is not ready to harvest on this account yet")
              state
            end

          {:error, reason} ->
            red("Mining harvest failed with #{clean_text(reason, "error")}")
            state
        end
      else
        yellow("Mining session is still running and needs more time to fill")
        state
      end
    else
      case call("/api/start-mine", %{"initData" => state.account}, proxy) do
        {:ok, body} ->
          green("Mining machine was started for this account")
          %{state | user: get(body, "user", user)}

        {:error, reason} ->
          red("Mining machine start failed with #{clean_text(reason, "error")}")
          state
      end
    end
  end

  defp run_video(state, proxy) do
    user = state.user
    reward = get(state.config, "video_reward_oil", 2000)

    if video_ready?(user) do
      pace(@ad_wait, "Watching rewarded video in")

      case call("/api/watch-video", %{"initData" => state.account}, proxy) do
        {:ok, body} ->
          green("Rewarded video was watched and credited #{reward} oil to this account")
          %{state | user: get(body, "user", user)}

        {:error, reason} ->
          red("Rewarded video request failed with #{clean_text(reason, "error")}")
          state
      end
    else
      yellow("Rewarded video is still on cooldown and was skipped this cycle")
      state
    end
  end

  defp run_campaigns(state, proxy) do
    case call("/api/campaigns", %{"initData" => state.account}, proxy) do
      {:ok, body} ->
        done = get(body, "doneCampIds", [])
        camps = get(body, "officialCamps", []) ++ get(body, "activeCamps", [])

        pending =
          Enum.reject(camps, fn camp ->
            id = get(camp, "_id")
            is_list(done) and id in done
          end)

        case pending do
          [] ->
            yellow("Every available campaign task was already completed")

          list ->
            green("Found #{plural(length(list), "campaign task")} to process")
            walk_campaigns(list, state, proxy, 0, 0)
        end

        state

      {:error, reason} ->
        red("Campaign list request failed with #{clean_text(reason, "error")}")
        state
    end
  end

  defp walk_campaigns([], _state, _proxy, claimed, skipped) do
    if skipped > 0 do
      yellow(
        "#{plural(skipped, "campaign task")} could not be settled without a manual channel join first"
      )
    end

    if claimed == 0 and skipped == 0 do
      yellow("No campaign task could be settled on this run")
    end
  end

  defp walk_campaigns([camp | rest], state, proxy, claimed, skipped) do
    title = clean_text(get(camp, "title", "campaign"), "campaign")
    id = get(camp, "_id")

    case call("/api/campaigns/verify", %{"initData" => state.account, "campaignId" => id}, proxy) do
      {:ok, _body} ->
        green("Campaign task #{title} was verified and paid its reward")
        pace(@campaign_wait, "Next campaign in")
        walk_campaigns(rest, state, proxy, claimed + 1, skipped)

      {:error, reason} ->
        text = clean_text(reason, "error")

        if join_required?(text) do
          pace(@campaign_wait, "Next campaign in")
          walk_campaigns(rest, state, proxy, claimed, skipped + 1)
        else
          red("Campaign task #{title} was refused with #{text}")
          walk_campaigns(rest, state, proxy, claimed, skipped)
        end
    end
  end

  defp run_tickets(state, proxy) do
    state
    |> craft_ticket(proxy)
    |> spin_tickets(proxy)
  end

  defp craft_ticket(state, proxy) do
    shards = get(state.user, "shards", 0)

    if is_number(shards) and shards >= 10 do
      case call("/api/craft-ticket", %{"initData" => state.account}, proxy) do
        {:ok, body} ->
          green("Ten shards were crafted into one lucky wheel ticket")
          %{state | user: get(body, "user", state.user)}

        {:error, reason} ->
          red("Ticket craft failed with #{clean_text(reason, "error")}")
          state
      end
    else
      yellow("Shard count is below ten so no ticket could be crafted")
      state
    end
  end

  defp spin_tickets(state, proxy) do
    tickets = get(state.user, "tickets", 0)

    if is_number(tickets) and tickets >= 1 do
      count = trunc(tickets)
      green("Found #{plural(count, "lucky wheel ticket")} to play")

      Enum.reduce(1..count, state, fn _spin, acc ->
        case call("/api/spin", %{"initData" => acc.account}, proxy) do
          {:ok, body} ->
            prize = spin_reward(get(body, "message", "a reward"))
            green("Lucky wheel spin paid #{prize} to this account")

            pace(@spin_wait, "Next spin in")
            %{acc | user: get(body, "user", acc.user)}

          {:error, reason} ->
            red("Lucky wheel spin failed with #{clean_text(reason, "error")}")
            acc
        end
      end)
    else
      yellow("No lucky wheel ticket is available on this account")
      state
    end
  end

  defp run_exchange(state, proxy) do
    balance = get(state.user, "oil_balance", 0)

    case pick_tier(balance) do
      nil ->
        yellow("Oil balance is below the smallest exchange tier and was kept for later")
        state

      {amount, receive} ->
        case call("/api/exchange", %{"initData" => state.account, "oilAmount" => amount}, proxy) do
          {:ok, body} ->
            green("Oil exchange converted #{amount} oil into #{receive} VND for this account")
            %{state | user: get(body, "user", state.user)}

          {:error, reason} ->
            red("Oil exchange failed with #{clean_text(reason, "error")}")
            state
        end
    end
  end

  defp pick_tier(balance) when is_number(balance) do
    Enum.find(@exchange_tiers, fn {amount, _receive} -> balance >= amount end)
  end

  defp pick_tier(_balance), do: nil

  defp login(init_data, proxy) do
    payload = %{"initData" => init_data, "customStartParam" => @ref_code}

    case request("/api/login", payload, proxy) do
      {:ok, body} ->
        case get(body, "success", false) do
          true ->
            {:ok,
             %{
               user: get(body, "user", %{}),
               config: get(body, "config", %{}),
               account: init_data,
               proxy: proxy
             }}

          _ ->
            cond do
              get(body, "not_joined", false) ->
                {:blocked, body}

              get(body, "is_maintenance", false) ->
                {:error, "the game is under maintenance right now"}

              true ->
                {:error, get(body, "error", "login was refused")}
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call(path, payload, proxy) do
    case request(path, payload, proxy) do
      {:ok, body} ->
        case get(body, "success", false) do
          true -> {:ok, body}
          _ -> {:error, get(body, "error", "request was refused")}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(path, payload, proxy) do
    url = String.to_charlist(@base_url <> path)
    body = YuurisanJSON.encode(payload)
    {profile, auth} = proxy_setup(proxy)

    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"accept", ~c"*/*"},
      {~c"accept-language", ~c"en-US,en;q=0.9"},
      {~c"origin", String.to_charlist(@base_url)},
      {~c"referer", String.to_charlist(@base_url <> "/")},
      {~c"user-agent",
       ~c"Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"}
    ]

    options = [ssl: [verify: :verify_none], timeout: 30_000, connect_timeout: 15_000] ++ auth

    case :httpc.request(
           :post,
           {url, headers, ~c"application/json", body},
           options,
           [body_format: :binary],
           profile
         ) do
      {:ok, {{_, status, _}, _, response}} ->
        case YuurisanJSON.decode(response) do
          {:ok, value} ->
            {:ok, value}

          {:error, _} ->
            {:error, "server returned status #{status}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp proxy_setup(nil), do: {:default, []}

  defp proxy_setup(line) do
    case parse_proxy(line) do
      {host, port, user, pass} -> proxy_profile(host, port, user, pass)
      {host, port} -> proxy_profile(host, port, "", "")
      nil -> {:default, []}
    end
  end

  defp proxy_profile(host, port, user, pass) do
    name = String.to_atom("proxy_#{host}_#{port}")
    address = {String.to_charlist(host), port}

    case :inets.start(:httpc, profile: name) do
      {:ok, _pid} -> :httpc.set_options([proxy: {address, []}, https_proxy: {address, []}], name)
      {:error, {:already_started, _pid}} -> :ok
      _ -> :ok
    end

    case user do
      "" -> {name, []}
      _ -> {name, [proxy_auth: {String.to_charlist(user), String.to_charlist(pass)}]}
    end
  end

  defp parse_proxy(line) do
    value =
      line
      |> String.trim()
      |> String.replace_prefix("http://", "")
      |> String.replace_prefix("https://", "")
      |> String.replace_prefix("socks5://", "")

    case String.split(value, "@") do
      [credentials, host_part] ->
        case String.split(credentials, ":") do
          [user, pass] -> with_host_port(host_part, user, pass)
          _ -> with_host_port(host_part, "", "")
        end

      [host_part] ->
        case String.split(host_part, ":") do
          [host, port] -> with_port(host, port)
          [host, port, user, pass] -> with_port_creds(host, port, user, pass)
          _ -> nil
        end
    end
  end

  defp with_host_port(host_part, user, pass) do
    case String.split(host_part, ":") do
      [host, port] -> with_port_creds(host, port, user, pass)
      _ -> nil
    end
  end

  defp with_port(host, port) do
    case Integer.parse(port) do
      {number, ""} -> {host, number}
      _ -> nil
    end
  end

  defp with_port_creds(host, port, user, pass) do
    case Integer.parse(port) do
      {number, ""} -> {host, number, user, pass}
      _ -> nil
    end
  end

  defp mask_proxy(line) do
    case parse_proxy(line) do
      {host, port, _user, _pass} -> "http://user:pass@#{mask_host(host)}:#{port}"
      {host, port} -> "http://user:pass@#{mask_host(host)}:#{port}"
      nil -> "http://user:pass@***:***"
    end
  end

  defp mask_host(host) do
    parts = String.split(host, ".")

    case parts do
      [a, _b, _c, d] ->
        "#{a}*****#{d}"

      _ ->
        if String.length(host) > 4 do
          String.slice(host, 0, 2) <> "*****" <> String.slice(host, -2, 2)
        else
          "***"
        end
    end
  end

  defp proxy_for([], _index), do: nil

  defp proxy_for(proxies, index) do
    Enum.at(proxies, rem(index, length(proxies)))
  end

  defp claimable_oil(user) do
    case parse_time(get(user, "last_claim_time")) do
      nil ->
        0.0

      last ->
        hours = max(0.0, (now_ms() - last) / 3_600_000)
        cap = capacity_hours(get(user, "capacity_lvl", 1))
        rate = machine_rate(get(user, "machine_lvl", 1)) / 24.0
        speed = 1.0 + get(user, "speed_lvl", 0) * 0.01

        rate * speed * min(hours, cap)
    end
  end

  defp capacity_hours(level) when is_number(level) do
    if level > 1, do: 3 + (level - 1) * 0.5, else: 3
  end

  defp capacity_hours(_level), do: 3

  defp machine_rate(level) when is_number(level) do
    Enum.at(@machine_rates, min(level, @max_machine)) || 10_000
  end

  defp machine_rate(_level), do: 10_000

  defp video_ready?(user) do
    case parse_time(get(user, "last_video_time")) do
      nil -> true
      last -> now_ms() - last >= @video_gap * 1000
    end
  end

  defp parse_time(nil), do: nil

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
      _ -> nil
    end
  end

  defp parse_time(_value), do: nil

  defp now_ms, do: System.system_time(:millisecond)

  defp join_required?(text) do
    lowered = String.downcase(text)

    String.contains?(lowered, "chưa tham gia") or
      String.contains?(lowered, "join") or
      String.contains?(lowered, "not a member") or
      String.contains?(lowered, "lỗi bot")
  end

  defp oil(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp oil(value), do: to_string(value)

  defp money(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 0)
  defp money(value), do: to_string(value)

  defp load_lines(name) do
    case File.read(Path.join(@root, name)) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      {:error, _} ->
        []
    end
  end

  defp load_settings do
    case File.read(Path.join(@root, "config.json")) do
      {:ok, content} ->
        case YuurisanJSON.decode(content) do
          {:ok, value} -> value
          {:error, _} -> default_settings()
        end

      {:error, _} ->
        settings = default_settings()
        File.write(Path.join(@root, "config.json"), YuurisanJSON.encode(settings))
        settings
    end
  end

  defp default_settings, do: %{"settings" => %{"sleep_seconds" => 3600}}

  defp sleep_seconds(settings) do
    case get(get(settings, "settings", %{}), "sleep_seconds", 3600) do
      value when is_integer(value) and value > 0 -> value
      value when is_float(value) and value > 0 -> trunc(value)
      _ -> 3600
    end
  end

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp get(_other, _key, default), do: default

  defp clean_text(value, fallback) when is_list(value) do
    clean_text(List.to_string(value), fallback)
  end

  defp clean_text(value, fallback) when is_atom(value) do
    clean_text(Atom.to_string(value), fallback)
  end

  defp clean_text(value, fallback) when is_number(value) do
    clean_text(to_string(value), fallback)
  end

  defp clean_text(value, fallback) when is_binary(value) do
    text =
      value
      |> String.replace(
        ["[", "]", "|", "#", "!", "@", "$", "%", "^", "&", "*", "(", ")", "-"],
        " "
      )

    case String.split(text) |> Enum.join(" ") do
      "" -> fallback
      cleaned -> cleaned
    end
  end

  defp clean_text(_value, fallback), do: fallback

  defp install_signal_handler do
    handler = fn ->
      IO.write("\n" <> @red <> @bold <> "Script stopped by user" <> @reset <> "\n")
      System.halt(0)
    end

    try do
      System.trap_signal(:sigint, handler)
    rescue
      _ -> :ok
    end

    try do
      System.trap_signal(:sigterm, handler)
    rescue
      _ -> :ok
    end
  end

  defp spin_reward(message) do
    text = clean_text(message, "a reward")
    parts = String.split(text, ":")

    if length(parts) > 1 do
      parts |> List.last() |> String.trim() |> case do
        "" -> text
        prize -> prize
      end
    else
      text
    end
  end

  defp plural(count, word) do
    if count == 1 do
      "#{count} #{word}"
    else
      "#{count} #{pluralize(word)}"
    end
  end

  defp pluralize(word) do
    if String.ends_with?(word, "y") do
      String.slice(word, 0, String.length(word) - 1) <> "ies"
    else
      word <> "s"
    end
  end

  defp pace(seconds, label) do
    countdown(seconds, label)
    :ok
  end

  defp countdown(seconds, label) do
    left = max(seconds, 0)

    if left >= 1 do
      width = frame(label, left, 0)
      tick(left, label, width)
    end
  end

  defp tick(0, _label, width) do
    IO.write("\r" <> String.duplicate(" ", width) <> "\r")
  end

  defp tick(left, label, width) do
    width = frame(label, left, width)
    :timer.sleep(1000)
    tick(left - 1, label, width)
  end

  defp frame(label, left, width) do
    text = label <> " " <> format_duration(left)
    IO.write("\r" <> @yellow <> @bold <> text <> @reset)
    max(width, String.length(text))
  end

  defp format_duration(total) do
    days = div(total, 86_400)
    hours = div(rem(total, 86_400), 3600)
    minutes = div(rem(total, 3600), 60)
    seconds = rem(total, 60)

    if days > 0 do
      pad(days) <> ":" <> pad(hours) <> ":" <> pad(minutes) <> ":" <> pad(seconds)
    else
      pad(hours) <> ":" <> pad(minutes) <> ":" <> pad(seconds)
    end
  end

  defp pad(value), do: String.pad_leading(Integer.to_string(value), 2, "0")

  defp green(message), do: IO.puts(@green <> @bold <> message <> @reset)
  defp yellow(message), do: IO.puts(@yellow <> @bold <> message <> @reset)
  defp red(message), do: IO.puts(@red <> @bold <> message <> @reset)
end

VuaDauMo.run()
