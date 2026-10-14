# Runs against every snapshot before it leaves prod. Replace names, emails and
# phone numbers with fake values. Only humans edit this file.
#
# Invoked by Peon as: mix run priv/peon/anonymize.exs
alias PeonTemplate.Repo
import Ecto.Query

Repo.update_all(
  from(u in "users", update: [set: [email: fragment("'user' || id || '@example.com'")]]),
  []
)
