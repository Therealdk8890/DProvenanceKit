enum SpanChange {
    case added
    case removed
    case reparented
    case contaminationChanged
}

let spanChanges: [SpanChange] = [.contaminationChanged]
var contaminationChangedSpans = 0
for sc in spanChanges {
    switch sc {
    case .added: break
    case .removed: break
    case .reparented: break
    case .contaminationChanged: contaminationChangedSpans += 1
    }
}
print(contaminationChangedSpans)
