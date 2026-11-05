import '../domain/models.dart';

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String formatDate(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

String memberName(List<Member> members, String id) => members
    .firstWhere((m) => m.id == id, orElse: () => Member(id: id, name: id))
    .name;
