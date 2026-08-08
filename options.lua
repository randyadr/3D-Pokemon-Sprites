-- Per-mod options schema for Pokemon Stadium Overworld Models.
-- ROM chooser plus Followers EX compatibility controls.
return {
  {
    key = "stadiumRomFile",
    type = "choice",
    label = "STADIUM ROM FILE",
    default = "choose",
    choices = {
      { "CHOOSE", "choose" },
    },
  },
  {
    key = "followersExCount",
    type = "choice",
    label = "FOLLOWER COUNT",
    default = "followers_ex",
    choices = {
      { "FOLLOWERS EX", "followers_ex" },
      { "0", 0 }, { "1", 1 }, { "2", 2 }, { "3", 3 },
      { "4", 4 }, { "5", 5 }, { "6", 6 },
    },
  },
}
