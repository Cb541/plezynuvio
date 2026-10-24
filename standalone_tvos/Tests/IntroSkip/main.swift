import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

let tvEpisode = NuvioEpisodeIdentity.from(
    videoId: "tt0903747:8:15", contentId: "tt0903747")
expect(tvEpisode == NuvioEpisodeIdentity(imdbID: "tt0903747", season: 8, episode: 15),
       "Stremio episode identity not extracted")

let explicitEpisode = NuvioEpisodeIdentity.from(
    videoId: nil, contentId: "tt0903747", season: 1, episode: 2)
expect(explicitEpisode?.episode == 2, "Explicit episode not accepted")
expect(NuvioEpisodeIdentity.from(videoId: nil, contentId: "tt0903747") == nil,
       "A movie/series ID alone must not produce a random intro")
expect(NuvioEpisodeIdentity.from(videoId: "tt0903747:1:2", contentId: nil)?.season == 1,
       "Episode identity should work with videoId alone")

let response = #"{"intro":{"start_sec":2.5,"end_sec":58},"no_intro":false}"#
let intro = NuvioIntroDB.decode(Data(response.utf8))
expect(intro?.contains(2.5) == true && intro?.contains(57) == true,
       "Valid timed intro should show Skip? inside its window")
expect(intro?.contains(58) == false && intro?.contains(1) == false,
       "Skip? must be hidden outside the actual intro window")
let noIntro = #"{"intro":{"start_sec":2.5,"end_sec":58},"no_intro":true}"#
expect(NuvioIntroDB.decode(Data(noIntro.utf8)) == nil,
       "Confirmed no-intro response should suppress Skip?")
let empty = #"{"intro":null,"no_intro":false}"#
expect(NuvioIntroDB.decode(Data(empty.utf8)) == nil,
       "Missing timestamp must not fabricate a skip point")
let invalid = #"{"intro":{"start_sec":59,"end_sec":20},"no_intro":false}"#
expect(NuvioIntroDB.decode(Data(invalid.utf8)) == nil,
       "Reject invalid time intervals")
print("Nuvio IntroDB parsing / episode identity tests: PASS")
