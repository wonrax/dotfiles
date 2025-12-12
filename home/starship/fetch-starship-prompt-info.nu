#!/usr/bin/env nu

# Fetch prompt info and write to rotating.json
# This script is meant to be run periodically by launchd/systemd

# Configuration
const LATITUDE = 10.78
const LONGITUDE = 106.69
const STATE_DIR = "~/.local/state/starship-prompt"
const OUTPUT_FILE = "~/.local/state/starship-prompt/rotating.json"

# Weather code to emoji mapping (WMO codes)
def weather_emoji [code: int]: nothing -> string {
    match $code {
        0 => "☀️"           # Clear sky
        1 | 2 | 3 => "⛅"   # Mainly clear, partly cloudy, overcast
        45 | 48 => "🌫️"    # Fog
        51 | 53 | 55 => "🌧️" # Drizzle
        56 | 57 => "🌧️"    # Freezing drizzle
        61 | 63 | 65 => "🌧️" # Rain
        66 | 67 => "🌧️"    # Freezing rain
        71 | 73 | 75 => "❄️" # Snow
        77 => "❄️"          # Snow grains
        80 | 81 | 82 => "🌧️" # Rain showers
        85 | 86 => "❄️"     # Snow showers
        95 => "⛈️"          # Thunderstorm
        96 | 99 => "⛈️"     # Thunderstorm with hail
        _ => "🌡️"          # Default
    }
}

# Weather code to condition text
def weather_condition [code: int]: nothing -> string {
    match $code {
        0 => "clear"
        1 => "mostly clear"
        2 => "partly cloudy"
        3 => "cloudy"
        45 | 48 => "foggy"
        51 | 53 | 55 | 56 | 57 => "drizzle"
        61 | 63 | 65 | 66 | 67 => "rainy"
        71 | 73 | 75 | 77 => "snowy"
        80 | 81 | 82 => "showers"
        85 | 86 => "snow showers"
        95 | 96 | 99 => "stormy"
        _ => "unknown"
    }
}

# AQI to text
def aqi_text [aqi: int]: nothing -> string {
    if $aqi <= 50 {
        "good"
    } else if $aqi <= 100 {
        "moderate"
    } else if $aqi <= 150 {
        "unhealthy-sg"
    } else if $aqi <= 200 {
        "unhealthy"
    } else if $aqi <= 300 {
        "very unhealthy"
    } else {
        "hazardous"
    }
}

# Fetch PR review requests from GitHub
def fetch_pr_reviews []: nothing -> record {
    let now = (date now | into int) // 1_000_000_000

    try {
        let result = (gh api graphql -f query='{ search(query: "is:pr is:open review-requested:@me", type: ISSUE, first: 100) { issueCount } }' | from json)
        let count = $result.data.search.issueCount

        if $count > 0 {
            { type: "pr", value: $"($count) reviews requested", updated: $now }
        } else {
            null
        }
    } catch {
        null
    }
}

# Fetch contribution streak from GitHub
def fetch_streak []: nothing -> record {
    let now = (date now | into int) // 1_000_000_000

    try {
        let result = (gh api graphql -f query='{ viewer { contributionsCollection { contributionCalendar { weeks { contributionDays { date contributionCount } } } } } }' | from json)

        # Flatten all contribution days and sort by date descending
        let days = ($result.data.viewer.contributionsCollection.contributionCalendar.weeks
            | each { |week| $week.contributionDays }
            | flatten
            | sort-by date --reverse)

        # Calculate streak (consecutive days with contributions, starting from today or yesterday)
        let today = (date now | format date "%Y-%m-%d")
        let yesterday = ((date now) - 1day | format date "%Y-%m-%d")

        # Find if we have contributions today
        let today_contributions = ($days | where date == $today | get -o 0.contributionCount | default 0)

        # Start counting from either today (if has contributions) or yesterday
        let start_date = if $today_contributions > 0 { $today } else { $yesterday }

        # Count consecutive days
        mut streak = 0
        mut check_date = if $today_contributions > 0 {
            (date now)
        } else {
            ((date now) - 1day)
        }

        for day in $days {
            let expected = ($check_date | format date "%Y-%m-%d")
            if $day.date == $expected and $day.contributionCount > 0 {
                $streak = $streak + 1
                $check_date = $check_date - 1day
            } else if $day.date == $expected and $day.contributionCount == 0 {
                break
            }
        }

        if $streak > 0 {
            { type: "streak", value: $"commit streak: ($streak)d", updated: $now }
        } else {
            null
        }
    } catch {
        null
    }
}

# Fetch weather from Open-Meteo
def fetch_weather []: nothing -> record {
    let now = (date now | into int) // 1_000_000_000

    try {
        let url = $"https://api.open-meteo.com/v1/forecast?latitude=($LATITUDE)&longitude=($LONGITUDE)&current=temperature_2m,weather_code&timezone=auto"
        let result = (http get $url)

        let temp = ($result.current.temperature_2m | into int)
        let code = $result.current.weather_code
        let emoji = (weather_emoji $code)
        let condition = (weather_condition $code)

        { type: "weather", value: $"($temp)° ($condition) ($emoji)", updated: $now }
    } catch {
        null
    }
}

# Fetch sunrise/sunset from Open-Meteo
def fetch_sun []: nothing -> record {
    let now = (date now | into int) // 1_000_000_000

    try {
        let url = $"https://api.open-meteo.com/v1/forecast?latitude=($LATITUDE)&longitude=($LONGITUDE)&daily=sunrise,sunset&timezone=auto&forecast_days=2"
        let result = (http get $url)

        let now_time = (date now)

        # Parse today's sunrise/sunset
        let today_sunrise = ($result.daily.sunrise.0 | into datetime)
        let today_sunset = ($result.daily.sunset.0 | into datetime)

        # Parse tomorrow's sunrise (in case we're past today's sunset)
        let tomorrow_sunrise = ($result.daily.sunrise.1 | into datetime)

        # Determine next sun event
        let next_event = if $now_time < $today_sunrise {
            { event: "sunrise", time: $today_sunrise }
        } else if $now_time < $today_sunset {
            { event: "sunset", time: $today_sunset }
        } else {
            { event: "sunrise", time: $tomorrow_sunrise }
        }

        let time_str = ($next_event.time | format date "%H:%M")
        let emoji = if $next_event.event == "sunrise" { "🌅" } else { "🌇" }
        let event = $next_event.event

        { type: "sun", value: $"($event) ($time_str) ($emoji)", updated: $now }
    } catch {
        null
    }
}

# Fetch AQI from Open-Meteo
def fetch_aqi []: nothing -> record {
    let now = (date now | into int) // 1_000_000_000

    try {
        let url = $"https://air-quality-api.open-meteo.com/v1/air-quality?latitude=($LATITUDE)&longitude=($LONGITUDE)&current=us_aqi&timezone=auto"
        let result = (http get $url)

        let aqi = ($result.current.us_aqi | into int)
        let text = (aqi_text $aqi)

        { type: "aqi", value: $"air: ($aqi)-($text)", updated: $now }
    } catch {
        null
    }
}

# Main execution
def main [] {
    # Ensure state directory exists
    let state_dir = ($STATE_DIR | path expand)
    mkdir $state_dir

    # Fetch all data in parallel-ish (nushell doesn't have true parallelism, but these are IO-bound)
    let pr = (fetch_pr_reviews)
    let streak = (fetch_streak)
    let weather = (fetch_weather)
    let sun = (fetch_sun)
    let aqi = (fetch_aqi)

    # Collect non-null items
    let items = ([$pr, $streak, $weather, $sun, $aqi] | where { |it| $it != null })

    # Write to file
    let output = { items: $items }
    let output_path = ($OUTPUT_FILE | path expand)
    $output | to json | save -f $output_path

    # Log success
    let count = ($items | length)
    print $"[(date now)] Fetched ($count) items"
}
